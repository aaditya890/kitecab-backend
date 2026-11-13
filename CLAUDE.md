# KiteCab: project overview and handoff

KiteCab (kitecab.com) is a taxi and cab booking business in **Chhattisgarh plus Nagpur**. Its main cities are Raipur, Bilaspur, Durg, Bhilai and Raigarh. The site is being rebuilt from scratch in this folder. Read this file first, then plan.

> A copy of this file is kept as `CLAUDE.md` in **both** repos, so it survives on GitHub. When you change one, update all three: `D:\web\kitecab\CLAUDE.md`, `kitecab-frontend/CLAUDE.md` and `kitecab-backend/CLAUDE.md`.

## About the user (owner/dev)
- Writes in Hinglish and casually ("bro", "okkie"). Reply in short, simple Hinglish with clear steps. When asked "mere side se kya karna hai", give a numbered list with no jargon.
- The client is premium (a "2L" project), so UI/UX must look professional, clean and modern, never "massy" or cluttered.
- Usually gives broad permission ("sab krdo"), but **secrets stay out of chat** (see Rules).

## Folder layout
| Path | What |
|---|---|
| `D:\web\kitecab\kitecab-frontend` | **New site.** Angular 21, static prerender plus admin panel. GitHub `aaditya890/kitecab-frontend`, branch `main` |
| `D:\web\kitecab\kitecab-backend` | **New API.** Vercel serverless functions plus Supabase SQL migrations. GitHub `aaditya890/kitecab-backend`, branch `main` |
| `D:\web\kitecab\_backup` | Data export of the live DB (2026-09-24) used to seed dev. Contains customer data, so never commit it. |
| `D:\web\Build-In-Angular\Kitecab_Taxi_Service\KiteCab` | **OLD live site** (Angular 17, on AWS S3/CloudFront). Runs on port 4200. Don't modify it. |
| `D:\web\Build-In-Angular\Kitecab_Taxi_Service\kitecab-whatsapp-api` | OLD WhatsApp/MSG91 relay API (Vercel), still used by the live site. |

## Rules (always)
1. **Never touch the LIVE Supabase project `zakyzpxuqdkhrrhgwccn`.** All dev work goes to the dev project `bnpxmvbylebxjgbuxihe` (Seoul region).
2. **Secrets** (Supabase secret key, Razorpay key secret and webhook secret, MSG91 authkey, IP salt):
   - They live only in `kitecab-backend/.env` (gitignored) and in Vercel env vars.
   - Never print them, never put them in chat, `.env.example` or commits, and never type them into web pages.
   - When pushing to Vercel, pipe values from `.env` without echoing them.
3. **AWS (S3/CloudFront) deploy of the new frontend is NOT done yet.** The user will decide when, because the main site lives there. Don't deploy it unasked.
4. **Keep these unchanged, byte for byte:**
   - Google tags: AW-17814447196, conversion label `AW-17814447196/8BPHCL3KuNMbENzIy65C` (Check-Price), G-F0DRP723DL, G-T836ZN3ZW3, GTM-53VC3R5Q. They lazy-load on first interaction or after 3.5s.
   - MSG91 integrated number 919009611602.
   - Invoice PDF layout: invoice no = booking id + 5125.
   - Public URLs of the home and policy pages.
5. **Testing safety:**
   - Put "TEST" in the name of any test booking.
   - Stub `gtag`/`dataLayer` during automated tests so no fake Ads conversions fire.
   - Never pay a payment link.
   - Cancel test bookings afterwards.
6. **Ports:** the old site runs on 4200, the new frontend on **4201**, the local API on **3000**.
7. Commit messages are plain English. Only commit or push when the user wants it (they generally do want work pushed to `main`).

## Architecture
```
Browser ──► kitecab-frontend (static prerendered HTML on S3/CloudFront later)
   │            ├─ public pages: home, /taxi/<from>-to-<to>, /taxi-service/<town>, city pages, policies
   │            └─ /admin (Supabase Auth login, data via RLS + RPCs)
   └─► kitecab-backend on Vercel  https://kitecab-backend.vercel.app/api
            ├─ POST /booking   create booking (RPC create_booking), reply fast, then payment link + WhatsApp in waitUntil
            ├─ GET  /pay-link  ?id&t  (HMAC pay-token) → {status: preparing|ready|paid, paymentLink}
            ├─ POST /enquiry   save lead with quoted_fare
            ├─ GET  /catalog   locations/fares (CDN cache 60s)
            ├─ POST /razorpay-webhook  (signature checked)
            └─ POST /admin/resend  admin actions: customer-whatsapp, admin-whatsapp, new-payment-link, driver-whatsapp, cancel-payment-links
                     │
                     ├─ Supabase dev project bnpxmvbylebxjgbuxihe (Postgres, RLS, is_admin()/is_staff())
                     ├─ Razorpay payment links (advance payment)
                     └─ MSG91 WhatsApp templates kc_* (all 6 APPROVED + enabled as of 2026-11-10)
```

### Frontend (`kitecab-frontend`)
- **Stack:**
  - Angular 21: zoneless, signals, OnPush.
  - Tailwind 4, self-hosted Poppins font.
  - `outputMode: static` with prerender. ~879 pages are built.
  - `@defer (hydrate never)` is used for heavy static sections.
  - Angular Material was removed. Budget warning is at 440 kB.
- **Commands:**
  - `npx ng serve --port 4201` runs the dev server.
  - `npm run build` builds the site and then the sitemap.
  - `npm test` runs 15 tests.
  - `npm run build:data` (python `scripts/build-catalog.py`) rebuilds SEO data from the CSV.
  - `npm run build:data:db` (`scripts/sync-fares.mjs`) rebuilds it from the DB.
- **Environments:**
  - `src/environments/environment.ts`: prod `apiUrl` is `https://kitecab-backend.vercel.app/api`.
  - Dev environment: `apiUrl` is `http://localhost:3000/api`.
  - `environment.common.ts` holds the Supabase URL and the publishable (public) key.
- **SEO data** in `src/app/data/`:
  - `seo-routes.json`: compact rows `[from, to, km, hatch, sedan, suv]`, 780 route pages.
  - `towns.json`: 77 town pages.
  - `popular-routes.json` and `place-stats.json`.
  - `places.ts` has the hand-written city info.
  - `route-content.ts` has the per-route copy (per-km rate, round-trip estimate).
- **SEO extras:**
  - Sitemap priorities: home 1.0, big cities 0.9, popular routes 0.8, towns 0.7, other routes 0.6.
  - JSON-LD: LocalBusiness, TaxiService AggregateOffer, BreadcrumbList, FAQPage.
  - OG image: `public/assets/og-kitecab.jpg` (1200×630).
- **SEO goal:** rank #1 in Chhattisgarh and Nagpur for taxi and route searches, beating **CoreCab (core-cab.com)** and **Rahul Travels**. Their sitemaps were studied, and we cover more routes and towns with real fares.
- **Booking widget** (`features/booking/booking-widget.*`, `shared/.../place-input.component.ts`):
  - Uber-style route card with a swap button.
  - Confirmation shows in ~2s.
  - After that it polls `/pay-link` and shows "Preparing your secure payment link…".
- **Header:** mobile right-side drawer with icon tiles (`layout/site-header.component.ts`, `core/config/navigation.ts`).
- **Admin** (`src/app/admin/`):
  - Dark sidebar layout.
  - Pages:
    - dashboard (Needs attention, KPIs, conversion ring)
    - enquiries/leads CRM (tabs, follow-ups, side panel)
    - bookings list and detail (assign driver, resend WhatsApp, new link, cancel → cancels unpaid links)
    - new booking (custom city picker)
    - customers, payments, activity log, staff & performance, drivers & cars, routes & fares, locations, rental & round trip, settings
  - Shared UI in `admin/ui/`:
    - `kc-contact`: call/WA/copy, with a `[compact]="true"` mode for tables.
    - `kc-badge`.
    - `kc-pager`.
  - Admin CSS classes live in `src/styles.css`: `kc-adm-card/btn/btn-primary/input/table/chip/chip-on/h1/label`.
  - **List-page style to follow** (as in `bookings-list.component.ts`):
    - Status chips on top.
    - One filter bar card (search with icon plus grey filled controls).
    - At most ~6 compact columns, no horizontal scroll at 1280px.
    - Clickable rows.
    - Quiet compact contact buttons.
    - Pill tags for dates and states.

### Backend (`kitecab-backend`)
- **Stack:** TypeScript Vercel functions, `route()` wrapper, zod validation, `waitUntil` for after-reply work. Region `bom1` (`vercel.json`), maxDuration 15s.
- **Commands:**
  - `npm run api`: local runner on :3000 (`scripts/local-api.mts`).
  - `npm test`: 22 tests.
  - `npm run typecheck`.
- **Use npm, not pnpm.** `package-lock.json` is the source of truth. Someone once ran pnpm and broke esbuild versions, which was fixed with `npm ci`. The stray untracked `pnpm-lock.yaml` and `pnpm-workspace.yaml` are not ours, and `.vercelignore` excludes them.
- **`lib/`:**
  - `booking.ts`: `createBooking` via the RPC, and `preparePayment`.
  - `pay-token.ts`: HMAC of `pay:<id>` with `env.ipSalt`, 24 characters.
  - `pricing.ts`: the server computes fares, the client never does.
  - `whatsapp.ts`: `kc_*` templates.
  - Also: `razorpay.ts`, `rate-limit.ts`, `admin-auth.ts`, `env.ts`.
- **SQL:** `supabase/migrations/001…011`, all applied on the dev project.

  | Migration | What it adds |
  |---|---|
  | 007 | admin_stats |
  | 008 | CRM, staff role, follow-ups, activity_log |
  | 009 | lead_counts due fix |
  | 010 | staff converted count |
  | 011 | `create_booking(jsonb, jsonb)` security definer, revoked from public/anon/authenticated |

  Combined setup and rollback scripts were built with `build-setup.py` → `setup_v2.sql` and `rollback_v2.sql`. Dev-only helpers are in `supabase/dev/`.
- **Deploy:** Vercel project `aaditya890s-projects/kitecab-backend`, linked to GitHub, so **a push to `main` auto-deploys**. Manual deploy: `npx vercel@48 deploy --prod --yes`.
  - Env vars are set for production and preview: SUPABASE_URL, SUPABASE_SECRET_KEY, RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET, RAZORPAY_WEBHOOK_SECRET, MSG91_AUTH_KEY, ALLOWED_ORIGINS (kitecab.com, www, localhost:4200/4201), IP_HASH_SALT.
  - WHATSAPP_TEST_NUMBER is intentionally unset.
- **Verified live (2026-11-10):**
  - `/api/catalog` 200 with CORS.
  - Bad pay-token → 404.
  - Admin without login → 401.
  - Webhook without signature → 401.

### Data facts
- Booking ids continue from **999970** (old max was 999969).
- Dev DB is seeded from the backup: 2851 bookings, 1660 customers, 1255 routes, plus enquiries and payments.
- Test bookings #999972–#999976 exist in dev. #999973 and #999974 are cancelled. #999972 is the user's own test and is still open, with an unpaid link.

## Status / TODO (as of 2026-11-13)
**Done:**
- Full rebuild of the site, admin panel and API.
- Backend live on Vercel with keys set.
- MSG91 kc_* templates approved.
- Booking speed fix: 5.3s → 2.0s.
- SEO pages and sitemap.
- Premium admin dashboard, bookings list and enquiries list redesign.

**In progress:** the enquiries list redesign in `admin/pages/enquiries.component.ts`:
- Compact table, chips tabs, filter bar.
- No-name leads show the mobile number as the title.
- The "By" column shows initials plus first name.
- Committed (4fef4b7) but not yet checked in the browser. Open `/admin/enquiries` at 1280px and confirm there is no horizontal scroll.

**User must do:**
- **Razorpay webhook:**
  - URL: `https://kitecab-backend.vercel.app/api/razorpay-webhook`
  - Secret: the `RAZORPAY_WEBHOOK_SECRET` from `.env`
  - Events: `payment_link.paid`, `payment_link.expired`, `payment_link.cancelled`
  - Keep the OLD webhook until launch day, then remove it, or customers get double WhatsApps.
- Rotate the leaked keys (Razorpay live secret, MSG91 authkey, old Supabase service key) around **December**, then update `.env` and the Vercel env vars.

**Later (ask the user first):**
- Customers page and other admin lists in the same clean style.
- AWS S3/CloudFront deploy of the new frontend (this is the launch).
- Decide the production DB for launch (new project, maybe Mumbai region) and the booking id sequence.
- Staff user accounts.
- Cancel test booking #999972.
