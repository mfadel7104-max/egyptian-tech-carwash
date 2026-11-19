# التقنية المصرية — النسخة V0.2

**Prototype only.** No official tax invoice, ZATCA compliance certification, App Store package or signed APK is included.

## Changes from V0.1
- Multi-service orders and quantities
- Customer name, phone and car plate
- Discount, initial partial payment and remaining balance
- Simplified / standard **draft** invoice classification
- SQL RPC with server-side prices, validation and atomic order/payment/draft writes
- Follow-up payment RPC (`record_order_payment`) prepared for a later screen

## Setup
1. Install Flutter SDK (3.24+ recommended) and Android SDK, or use a hosted CI build environment.
2. Create a Supabase project and run `supabase/schema.sql` **once** in SQL Editor, then `supabase/upgrade_v0_2.sql`.
3. In Supabase Authentication, create a test user. Assign role in SQL Editor using a **trusted admin session**:
   `update public.profiles set role='admin' where id=(select id from auth.users where email='YOUR_EMAIL');`
   Never expose the service-role key in the mobile app.
4. Generate platform scaffolding if not present: `flutter create --platforms=android,ios .`
5. Run `flutter pub get` and then:
   `flutter run --dart-define=SUPABASE_URL=https://PROJECT.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLISHABLE_OR_ANON_KEY`
6. For Android cloud builds, configure Flutter SDK and secrets in a CI provider. For iOS, a macOS build/signing service and Apple developer provisioning are needed.

## Caveats / before production
- SQL `schema.sql` is a one-time baseline; migration v0.2 assumes that baseline exists.
- Discount editing is not permission-restricted yet. Do not deploy to real staff until discounts are permission-controlled.
- Employee order read policy only shows their own orders; customer orders need authenticated `customer_id` linking (not implemented).
- The daily report summarizes fully paid orders, not actual receipts; partial payments require a separate payments-based cash report.
- Existing V0.1 orders have no corresponding order_items/payments rows. A data backfill will be required for existing records.
- Invoice drafts do **not** meet ZATCA electronic invoicing requirements; integrate a compliant provider before issuing legal invoices.
- Test on actual devices, perform database security review, add privacy/consent, rate limits, idempotency and robust financial rounding before production.
- Prices in the sample catalog are **illustrative** and assumed VAT-inclusive at 15%.
