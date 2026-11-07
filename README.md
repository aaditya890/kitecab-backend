# KiteCab backend

Vercel API (catalog, enquiry, booking, Razorpay webhook, admin actions, MSG91 WhatsApp) and the
Supabase database (SQL in `supabase/`).

## Database

The live site keeps its own Supabase project (`zakyzpxuqdkhrrhgwccn`) — nothing here touches it.
Development uses a separate project.

**New project, step by step**

1. Supabase → New project (region Mumbai).
2. SQL Editor → `supabase/dev/000_legacy_tables.sql` (empty copies of the old `kitecab` and `payments` tables).
3. Load the backup: put the project's URL + secret key in `.env`, then
   `npx tsx scripts/import-backup.mts ../_backup/2026-09-24` (refuses to run on the live project).
4. SQL Editor → `supabase/setup_v2.sql` (all migrations; the result shows row counts).
5. Optional fresh start (keeps places and prices): `supabase/dev/clear_old_bookings.sql`.
6. Authentication → Users → Add user (admin email + password, auto-confirm), then run the
   admin bootstrap at the end of `migrations/002_rls.sql`. More people: Admin → Staff & performance.

| File | Use |
|---|---|
| `supabase/migrations/001..010` | Source of truth. `python supabase/build-setup.py` rebuilds `setup_v2.sql`. |
| `supabase/setup_v2.sql` | Everything in one run. |
| `supabase/rollback_v2.sql` | Removes everything `setup_v2.sql` created. |
| `supabase/check_live_tables.sql` | Read-only fingerprint of the live tables. |

| Migration | Adds |
|---|---|
| 001 | Settings, locations, routes, rentals, round-trip rates, people, drivers, cars, enquiries, bookings, payments |
| 002 | Row level security (`is_admin()`) |
| 003 | Copies the old data into the new tables (re-runnable for a newer export) |
| 004 | Spam-limit columns |
| 005 | Customer login (my bookings + driver details), coupons |
| 006 | Search indexes, admin list views, `admin_dashboard()` |
| 007 | `admin_stats(days)` for the dashboard charts |
| 008 | Staff role, lead follow-ups, office booking fields, automatic activity log |
| 009 | "Call now" counts new leads; admin display name |
| 010 | Staff performance counts bookings made from leads |

Business rules live in the `settings` table (Admin → Settings): `advance_percent`,
`admin_whatsapp_numbers`, `support_phone`, `support_email`, `business`, `booking_open`,
`whatsapp_sender`, `whatsapp_namespace`. Places, routes and packages have on/off switches.

## API (`api/`)

| Endpoint | Called by | Does |
|---|---|---|
| `GET /api/catalog` | Website booking form | Places, one-way fares, rentals, round-trip rates from the DB; CDN-cached 60 s |
| `POST /api/enquiry` | "Check price" | Saves the lead (with the lowest fare shown), WhatsApp `kc_enquiry_admin` |
| `POST /api/booking` | Booking form | Fare **from the DB**, saves customer + booking, Razorpay advance link, `kc_booking_admin` + `kc_booking_customer` |
| `POST /api/razorpay-webhook` | Razorpay | Verifies signature, marks PAID once, confirms booking, `kc_payment_customer` + `kc_payment_admin` |
| `POST /api/admin/resend` | Admin panel (login token, admin role) | `customer-whatsapp`, `admin-whatsapp`, `new-payment-link`, `driver-whatsapp` (`kc_driver_assigned`) |

WhatsApp templates: `docs/whatsapp-templates-v2.md` (exact texts and variable order; code in `lib/whatsapp.ts`).
Spam limits per 10 min: enquiries 20/IP, 10/mobile · bookings 6/IP, 4/mobile.

```jsonc
// POST /api/enquiry
{ "serviceType": "oneway", "pickup": "Raipur", "dropOrPackage": "Bilaspur", "mobile": "9876543210" }

// POST /api/booking  (round-trip also needs waitingTime + approxDistanceKm; local-rental needs rentalPackageId)
{
  "bookingType": "oneway", "carType": "Sedan", "pickup": "Raipur", "drop": "Bilaspur",
  "customer": { "fullName": "Name", "mobile": "9876543210", "email": "a@b.com", "passengers": 2,
                "pickupAddress": "Telibandha", "pickupDate": "2026-12-01", "pickupTime": "9:00 AM" }
}
```

## Develop & test

```bash
npm install
npm test          # pricing, WhatsApp payloads, signature, validation, handlers
npm run typecheck
npm run dev       # vercel dev (needs `vercel login` once and a local .env)
```

`WHATSAPP_TEST_NUMBER` in `.env` sends every WhatsApp to that one number — use it while testing,
leave it empty in production.

## Deploy (Vercel, free Hobby plan, region bom1)

1. Vercel → Add New Project → import `aaditya890/kitecab-backend` (no build settings).
2. Settings → Environment Variables: every key in `.env.example` (new project URL + secret key,
   Razorpay, MSG91, `ALLOWED_ORIGINS`, `IP_HASH_SALT`).
3. Deploy. API base: `https://<project>.vercel.app/api` — set it as `apiUrl` in the frontend's
   `src/environments/environment.ts`.
4. **Launch day only:** Razorpay → Webhooks → URL `https://<project>.vercel.app/api/razorpay-webhook`,
   events `payment_link.paid`, `payment_link.expired`, `payment_link.cancelled`, new secret →
   `RAZORPAY_WEBHOOK_SECRET`. Remove the old webhook at the same time (two would send duplicate WhatsApps).
