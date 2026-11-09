# Booking Engine — rules for this project

This project uses **@profitstudio/booking-engine** (version: see
`booking-engine.lock.json`). The engine owns booking data, availability, the
database, booking emails (the `booking-mailer` Edge Function) and the admin
dashboard. The public website design is yours.

Short guide: `node_modules/@profitstudio/booking-engine/docs/BUILD-A-SITE.md` · full contract: `docs/INTEGRATION.md`
Connect Supabase and email: `npx booking-engine connect` (INTEGRATION.md §11)

## Always

- Get booking data only through the engine instance in `src/lib/engine.ts`.
- Take preview sample data from a preset: the engine's `hairSalonPreset`, or the site's
  own `Preset` for any other kind of business (INTEGRATION.md §5), also passed to
  `<BookingAdmin presets>`.
- Show the slots `getAvailability()` returns; send `slot.startsAt` back unchanged.
- Show dates and times in the business time zone (`business.timezone`).
- Book in two steps: `requestBooking()` emails a 6-digit code, then `verifyBooking()`
  with that code. Offer "Send a new code" (`resendVerificationCode()`) and
  "Choose another time" (`cancelBookingRequest()`, then reload availability).
- Handle `ok: false` on every engine call (see the error table in INTEGRATION.md).
- Show success only when `verifyBooking()` returned `ok: true`, and say whether the
  booking is a request (`pending`, the business will confirm) or `confirmed`.
- When `business.policies.onlineBookingEnabled` is false, show contact details instead of the form.
- Every Book button on the page reaches the booking section in every state (also while
  booking is off, loading or failed) — never a click that does nothing.
- Keep the packaged admin dashboard on `/admin/` (`admin/index.html`).
- Make text, photos, the logo, brand colours or the heading style owner-editable by
  declaring a field in the site's content schema (`defineSiteContent`, passed to
  `<BookingAdmin content>`) and rendering its resolved value; the dashboard's Website
  page builds its editor from the schema. Defaults are the website's own copy: until
  the owner publishes, the site shows exactly them.

## Never

- Edit `supabase/migrations/*_booking_engine_*.sql`, `supabase/functions/booking-mailer/`,
  `booking-engine.lock.json` or `node_modules`.
- Query booking tables, call `booking_*` RPCs, or import `@supabase/supabase-js` for booking data.
- Put a Supabase secret key or an email provider key (Resend `re_…`) in a `VITE_` variable,
  in source code, in `.env` files of the website or in Git. Provider keys are Edge Function secrets.
- Compute availability in the browser, skip the code step or fake a confirmation
  (preview mode saves nothing and sends no email).
- Send booking emails from the website or add another email service: the engine sends them.
- Rebuild or fork the admin dashboard.
- Render owner content as HTML (`dangerouslySetInnerHTML`, `innerHTML`) or build image
  URLs yourself: render text as text, images from the resolved `src`/`alt`.
- Put services, prices, hours, the address, phone or email in the content schema:
  they come from the engine.
- Rename or reuse a content field id once the site is live: the owner's text is stored
  under it. Add a new id instead.

## Checks

```bash
npx booking-engine doctor               # project
npx booking-engine doctor --dist dist   # after npm run build
```

A new feature (payments, SMS, staff…) needs a new engine version, not custom
database code in this project.
