-- Run in Supabase SQL Editor. MVP: no legally valid tax invoices generated.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 role text not null default 'customer' check (role in ('admin','employee','customer')),
 display_name text, created_at timestamptz not null default now()
);
create table if not exists public.branches (
 id uuid primary key default gen_random_uuid(), name text not null,
 address text, google_maps_url text, created_at timestamptz not null default now()
);
create table if not exists public.services (
 id uuid primary key default gen_random_uuid(), name text not null,
 price_sar numeric(12,2) not null check (price_sar >= 0), active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.orders (
 id uuid primary key default gen_random_uuid(), created_at timestamptz not null default now(),
 employee_id uuid not null references auth.users(id), customer_id uuid references auth.users(id),
 plate text not null, customer_name text, service_id uuid not null references public.services(id),
 service_name text not null, total_sar numeric(12,2) not null check(total_sar >= 0),
 vat_sar numeric(12,2) not null check(vat_sar >= 0),
 payment_status text not null check(payment_status in ('paid','unpaid')),
 payment_method text check(payment_method in ('cash','card') or payment_method is null),
 status text not null default 'received' check(status in ('received','in_progress','completed','cancelled'))
);
create table if not exists public.invoice_drafts (
 id uuid primary key default gen_random_uuid(), order_id uuid not null unique references public.orders(id),
 kind text not null default 'simplified' check(kind in ('simplified','standard')),
 state text not null default 'draft' check(state = 'draft'),
 created_at timestamptz not null default now()
);
create index if not exists orders_created_at_idx on public.orders(created_at desc);
create index if not exists orders_employee_idx on public.orders(employee_id);
create index if not exists orders_customer_idx on public.orders(customer_id);

create or replace function public.my_role() returns text language sql stable security definer
set search_path = '' as $$select role from public.profiles where id = (select auth.uid())$$;
revoke all on function public.my_role() from public;
grant execute on function public.my_role() to authenticated;

alter table public.profiles enable row level security;
alter table public.branches enable row level security;
alter table public.services enable row level security;
alter table public.orders enable row level security;
alter table public.invoice_drafts enable row level security;

create policy "own profile read" on public.profiles for select to authenticated using (id = (select auth.uid()) or public.my_role() = 'admin');
create policy "services visible" on public.services for select to authenticated using (active or public.my_role() = 'admin');
create policy "branches visible" on public.branches for select to authenticated using (true);
create policy "orders read restricted" on public.orders for select to authenticated
using (public.my_role() = 'admin' or (public.my_role() = 'employee' and employee_id = (select auth.uid())) or customer_id = (select auth.uid()));
create policy "draft read admin" on public.invoice_drafts for select to authenticated using (public.my_role() = 'admin');

-- Never accept client-supplied price, role, employee_id or paid amount.
create or replace function public.create_wash_order(p_plate text, p_customer_name text, p_service_id uuid, p_payment_method text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_service public.services%rowtype; v_id uuid; v_paid boolean;
begin
 if (select auth.uid()) is null or public.my_role() not in ('admin','employee') then raise exception 'Not authorized'; end if;
 if length(trim(coalesce(p_plate,''))) < 2 or length(p_plate) > 30 then raise exception 'Invalid plate'; end if;
 if length(coalesce(p_customer_name,'')) > 150 then raise exception 'Invalid name'; end if;
 if p_payment_method not in ('unpaid','cash','card') then raise exception 'Invalid payment'; end if;
 select * into v_service from public.services where id = p_service_id and active = true;
 if not found then raise exception 'Service unavailable'; end if;
 v_paid := p_payment_method <> 'unpaid';
 insert into public.orders(employee_id,plate,customer_name,service_id,service_name,total_sar,vat_sar,payment_status,payment_method)
 values ((select auth.uid()),trim(p_plate),nullif(trim(p_customer_name),''),v_service.id,v_service.name,
 v_service.price_sar,round(v_service.price_sar * 15 / 115,2),
 case when v_paid then 'paid' else 'unpaid' end,
 case when v_paid then p_payment_method else null end)
 returning id into v_id;
 insert into public.invoice_drafts(order_id) values (v_id);
 return v_id;
end $$;
revoke all on function public.create_wash_order(text,text,uuid,text) from public;
grant execute on function public.create_wash_order(text,text,uuid,text) to authenticated;

create or replace function public.daily_sales_summary()
returns table(day date,orders_count bigint,paid_total_sar numeric)
language plpgsql security definer set search_path = '' as $$
begin
 if public.my_role() <> 'admin' then raise exception 'Not authorized'; end if;
 return query select (o.created_at at time zone 'Asia/Riyadh')::date, count(*),
 coalesce(sum(case when o.payment_status = 'paid' and o.status <> 'cancelled' then o.total_sar else 0 end),0)
 from public.orders o group by 1 order by 1 desc limit 30;
end $$;
revoke all on function public.daily_sales_summary() from public;
grant execute on function public.daily_sales_summary() to authenticated;

-- Auto-create a least-privileged profile when an Auth user is created.
create or replace function public.create_profile_for_new_user() returns trigger language plpgsql security definer
set search_path = '' as $$begin insert into public.profiles(id,role) values(new.id,'customer'); return new; end$$;
drop trigger if exists on_auth_user_created_carwash on auth.users;
create trigger on_auth_user_created_carwash after insert on auth.users for each row execute function public.create_profile_for_new_user();

insert into public.services(name,price_sar) select v.name,v.price from (values
('غسيل خارجي وداخلي',45.00::numeric),('غسيل بخار',80.00),('تلميع شامل',150.00),('باقة VIP',220.00)) as v(name,price)
where not exists (select 1 from public.services);
