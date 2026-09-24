# KiteCab backend

Vercel API (booking, enquiry, Razorpay, MSG91 WhatsApp) + Supabase database.

## Database setup (Supabase SQL editor, run in order)

| File | What it does | When |
|---|---|---|
| `supabase/migrations/001_schema.sql` | New tables, enums, settings, round-trip rates, views | Once |
| `supabase/migrations/002_rls.sql` | Security rules; follow the admin bootstrap note at the bottom | Once |
| `supabase/migrations/003_migrate_legacy_data.sql` | Copies legacy `kitecab` JSON into the new tables (cleans junk, keeps booking IDs and prices) | Any time before launch; **again at cutover** |

Nothing here changes the legacy `kitecab` / `payments` data, so the live site keeps working.

## Changing business rules later — no code change needed

Edit rows in `settings` (admin panel will expose these):

- `advance_percent` — currently 20
- `admin_whatsapp_numbers` — who gets admin alerts
- `support_phone`, `support_email`, `business` (invoice name/address/GSTIN)
- `booking_open` — master switch for online booking

Round-trip pricing lives in `round_trip_rates`; locations/routes/packages have `is_active` switches.
