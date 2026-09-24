# KiteCab backend

Vercel API (booking, enquiry, Razorpay, MSG91 WhatsApp) + Supabase database.

## Database setup (Supabase SQL editor)

The live site's tables `kitecab` and `payments` are **only read, never changed**.

| File | Use |
|---|---|
| `supabase/check_live_tables.sql` | Read-only fingerprint of the live tables. Run **before and after** setup — the `structure` rows must match. |
| `supabase/setup_v2.sql` | **One file, one Run.** Creates all new tables and copies the data. Re-run on launch day to pick up the latest bookings. |
| `supabase/rollback_v2.sql` | Removes everything `setup_v2.sql` created. |
| `supabase/migrations/001..004` | Source files that `setup_v2.sql` is generated from. |

After setup, create the admin login (see the end of `migrations/002_rls.sql`).

## Changing business rules later — no code change needed

Edit rows in `settings` (admin panel will expose these):

- `advance_percent` — currently 20
- `admin_whatsapp_numbers` — who gets admin alerts
- `support_phone`, `support_email`, `business` (invoice name/address/GSTIN)
- `booking_open` — master switch for online booking

Round-trip pricing lives in `round_trip_rates`; locations/routes/packages have `is_active` switches.

## API (Vercel functions in `api/`)

| Endpoint | Called by | Does |
|---|---|---|
| `POST /api/enquiry` | Website "Check Price" | Validates mobile, saves enquiry, sends `admin_enquiry` |
| `POST /api/booking` | Website booking form | Calculates fare **from the DB**, saves customer + booking, creates Razorpay advance link, sends `admin_booking_enquiry` + `customer_booking_enquiry` / `customer_local_rental_enquiry`. Returns `{ bookingId, fare, advanceAmount, paymentLink }` |
| `POST /api/razorpay-webhook` | Razorpay | Verifies signature, marks payment PAID once, confirms booking, sends both payment templates |
| `POST /api/admin/resend` | Admin panel (Supabase login token) | Re-send customer/admin WhatsApp, or cancel old link and issue a new one |

Fares are read by the website directly from Supabase (`route_fares` view, read-only), so browsing costs no Vercel calls.

Spam limits (per 10 min): enquiries 20/IP, 10/mobile · bookings 6/IP, 4/mobile.

### Request examples

```jsonc
// POST /api/enquiry
{ "serviceType": "oneway", "pickup": "Raipur", "dropOrPackage": "Bilaspur", "mobile": "9876543210" }

// POST /api/booking  (oneway | round-trip needs drop; round-trip also waitingTime + approxDistanceKm;
//                     local-rental needs rentalPackageId)
{
  "bookingType": "oneway", "carType": "Sedan", "pickup": "Raipur", "drop": "Bilaspur",
  "customer": { "fullName": "Name", "mobile": "9876543210", "email": "a@b.com", "passengers": 2,
                "pickupAddress": "Telibandha", "pickupDate": "2026-10-01", "pickupTime": "9:00 AM" }
}
```

## Develop & test

```bash
npm install
npm test          # pricing, WhatsApp payload shape, signature, validation, handlers
npm run typecheck
npm run dev       # vercel dev (needs `vercel login` once and a local .env)
```

## Deploy (Vercel, free Hobby plan)

1. Vercel -> Add New Project -> import `aaditya890/kitecab-backend` (no build settings needed).
2. Settings -> Environment Variables: every key in `.env.example`.
3. Deploy. API base: `https://<project>.vercel.app/api`.
4. **Launch day only:** Razorpay -> Webhooks -> change URL to `https://<project>.vercel.app/api/razorpay-webhook`,
   events: `payment_link.paid`, `payment_link.expired`, `payment_link.cancelled`, new secret -> `RAZORPAY_WEBHOOK_SECRET`.
   Keep the old webhook until then (two webhooks would send duplicate WhatsApps).
