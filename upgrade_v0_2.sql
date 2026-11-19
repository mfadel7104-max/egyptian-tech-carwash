-- Apply AFTER schema.sql. Prototype order workflow; NOT a ZATCA invoice engine.
create table if not exists public.order_items (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id) on delete restrict,
 service_id uuid not null references public.services(id),
 service_name text not null,
 unit_price_sar numeric(12,2) not null check(unit_price_sar>=0),
 quantity integer not null check(quantity between 1 and 20),
 line_total_sar numeric(12,2) not null check(line_total_sar>=0)
);
create table if not exists public.payments (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id),
 amount_sar numeric(12,2) not null check(amount_sar>0),
 method text not null check(method in ('cash','card')),
 employee_id uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.orders add column if not exists discount_sar numeric(12,2) not null default 0 check(discount_sar>=0);
alter table public.orders add column if not exists customer_phone text;
create index if not exists payments_order_idx on public.payments(order_id);
create index if not exists order_items_order_idx on public.order_items(order_id);
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
create policy "staff view order items" on public.order_items for select to authenticated
 using (exists(select 1 from public.orders o where o.id=order_id and (public.my_role()='admin' or (public.my_role()='employee' and o.employee_id=(select auth.uid())) or o.customer_id=(select auth.uid()))));
create policy "staff view payments" on public.payments for select to authenticated
 using (exists(select 1 from public.orders o where o.id=order_id and (public.my_role()='admin' or (public.my_role()='employee' and o.employee_id=(select auth.uid())) or o.customer_id=(select auth.uid()))));
-- Server calculates all prices; discount capped at total; one atomic transaction.
create or replace function public.create_wash_order_v2(
 p_plate text, p_customer_name text, p_customer_phone text,
 p_items jsonb, p_discount_sar numeric, p_initial_payment_sar numeric, p_payment_method text,
 p_invoice_kind text default 'simplified'
) returns uuid language plpgsql security definer set search_path = '' as $$
declare v_item jsonb; v_service public.services%rowtype; v_order uuid;
 v_subtotal numeric(12,2):=0; v_total numeric(12,2); v_count integer;
begin
 if (select auth.uid()) is null or public.my_role() not in ('admin','employee') then raise exception 'Not authorized'; end if;
 if length(trim(coalesce(p_plate,''))) < 2 or length(p_plate)>30 then raise exception 'Invalid plate'; end if;
 if length(coalesce(p_customer_name,''))>150 or length(coalesce(p_customer_phone,''))>25 then raise exception 'Invalid customer'; end if;
 if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 15 then raise exception 'Invalid items'; end if;
 if p_invoice_kind not in ('simplified','standard') then raise exception 'Invalid invoice kind'; end if;
 if p_discount_sar is null or p_discount_sar<0 then raise exception 'Invalid discount'; end if;
 if p_initial_payment_sar is null or p_initial_payment_sar<0 then raise exception 'Invalid payment amount'; end if;
 if p_payment_method not in ('cash','card','unpaid') then raise exception 'Invalid payment method'; end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(v_item) <> 'object' or (v_item->>'quantity') !~ '^[0-9]+$' then raise exception 'Invalid item'; end if;
  v_count:=(v_item->>'quantity')::integer;
  if v_count not between 1 and 20 then raise exception 'Invalid quantity'; end if;
  select * into v_service from public.services where id=(v_item->>'service_id')::uuid and active=true;
  if not found then raise exception 'Service unavailable'; end if;
  v_subtotal:=v_subtotal+v_service.price_sar*v_count;
 end loop;
 if p_discount_sar>v_subtotal then raise exception 'Discount exceeds subtotal'; end if;
 v_total:=v_subtotal-p_discount_sar;
 if p_initial_payment_sar>v_total then raise exception 'Payment exceeds total'; end if;
 if (p_initial_payment_sar=0 and p_payment_method<>'unpaid') or (p_initial_payment_sar>0 and p_payment_method='unpaid') then raise exception 'Payment method mismatch'; end if;
 insert into public.orders(employee_id,plate,customer_name,customer_phone,service_id,service_name,total_sar,vat_sar,discount_sar,payment_status,payment_method)
 values((select auth.uid()),trim(p_plate),nullif(trim(p_customer_name),''),nullif(trim(p_customer_phone),''),v_service.id,'خدمات متعددة',v_total,round(v_total*15/115,2),p_discount_sar,
 case when p_initial_payment_sar=v_total then 'paid' else 'unpaid' end,
 case when p_initial_payment_sar>0 then p_payment_method else null end) returning id into v_order;
 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_service from public.services where id=(v_item->>'service_id')::uuid and active=true;
  v_count:=(v_item->>'quantity')::integer;
  insert into public.order_items(order_id,service_id,service_name,unit_price_sar,quantity,line_total_sar)
  values(v_order,v_service.id,v_service.name,v_service.price_sar,v_count,v_service.price_sar*v_count);
 end loop;
 if p_initial_payment_sar>0 then
  insert into public.payments(order_id,amount_sar,method,employee_id) values(v_order,p_initial_payment_sar,p_payment_method,(select auth.uid()));
 end if;
 insert into public.invoice_drafts(order_id,kind) values(v_order,p_invoice_kind);
 return v_order;
end $$;
revoke all on function public.create_wash_order_v2(text,text,text,jsonb,numeric,numeric,text,text) from public;
grant execute on function public.create_wash_order_v2(text,text,text,jsonb,numeric,numeric,text,text) to authenticated;

create or replace function public.record_order_payment(p_order_id uuid,p_amount_sar numeric,p_method text)
returns void language plpgsql security definer set search_path='' as $$
declare v_order public.orders%rowtype; v_paid numeric(12,2);
begin
 if public.my_role() not in ('admin','employee') then raise exception 'Not authorized'; end if;
 select * into v_order from public.orders where id=p_order_id for update;
 if not found or v_order.status='cancelled' then raise exception 'Order unavailable'; end if;
 if public.my_role()='employee' and v_order.employee_id<>(select auth.uid()) then raise exception 'Not authorized'; end if;
 if p_amount_sar is null or p_amount_sar<=0 or p_method not in ('cash','card') then raise exception 'Invalid payment'; end if;
 select coalesce(sum(amount_sar),0) into v_paid from public.payments where order_id=p_order_id;
 if v_paid+p_amount_sar>v_order.total_sar then raise exception 'Payment exceeds balance'; end if;
 insert into public.payments(order_id,amount_sar,method,employee_id) values(p_order_id,p_amount_sar,p_method,(select auth.uid()));
 update public.orders set payment_status=case when v_paid+p_amount_sar=total_sar then 'paid' else 'unpaid' end,
 payment_method=case when v_paid=0 then p_method else payment_method end where id=p_order_id;
end $$;
revoke all on function public.record_order_payment(uuid,numeric,text) from public;
grant execute on function public.record_order_payment(uuid,numeric,text) to authenticated;
