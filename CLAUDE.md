# Pet Grooming Studio "Groom Card" Starter — project rules

A one-page booking website for an independent dog grooming studio, shipped as **Brindle
Grooming Studio** (a fictional, one-dog-at-a-time grooming studio in Linden Hills,
Minneapolis) for the owner to make their own. Its identity lives in `src/site.config.ts`;
`CUSTOMIZE.md` is the prompt that personalizes it. Built around
**@profitstudio/booking-engine** **2.0.0-beta.3** (pinned; lock in `booking-engine.lock.json`).
The engine owns booking; this project owns the public design.

Read before changing anything:
- `BOOKING_ENGINE.md` — the engine's rules (engine-owned; `npx booking-engine sync` replaces it).
- `node_modules/@profitstudio/booking-engine/docs/INTEGRATION.md` — the full contract. It wins on technical points.
- `DESIGN.md` — the visual system. `PHOTOS.md` — photo sources and licences.

## The Live Demo layer — leave it alone

- `src/demo/` is the public Live Demo's in-browser engine and sample data. Only
  `npm run dev:demo` / `npm run build:demo` use it (`vite --mode demo` defines
  `__BOOKING_DEMO__`); in every other build it is compiled out. Never read, edit
  or "fix" it while customizing the website.
- Keep the `__BOOKING_DEMO__ ? … : …` branches as they are: the demo wording
  (no email is sent) must stay true in the demo, and the real wording in production.
- `src/demo/engine/` is vendored from the Niche Pack workspace — edit it there.
- `src/admin-main.tsx` passes `emailDelivery={__BOOKING_DEMO__ ? 'none' : undefined}`:
  only the demo's dashboard says no email is sent. Never set it on a real site.

## Engine boundaries (from BOOKING_ENGINE.md)

- All booking data goes through the ONE instance in `src/lib/engine.ts`. Never import
  `@supabase/supabase-js` for booking data, call `booking_*` RPCs or write SQL for booking tables.
- Never edit `supabase/migrations/*_booking_engine_*.sql`, `supabase/functions/booking-mailer/`,
  `booking-engine.lock.json` or `node_modules`.
- Only the publishable key may reach the website (`VITE_SUPABASE_URL` + `VITE_SUPABASE_PUBLISHABLE_KEY`,
  both or neither). Never a secret/`service_role` key, never an email provider key, in any file or `VITE_` variable.
- Show only the slots `getAvailability()` returns; send `slot.startsAt` back unchanged; show dates and
  times in `business.timezone`. Never compute availability in the browser — the calendar only reshapes
  engine data with the engine's helpers (`monthGrid`, `groupSlotsByPartOfDay`, `isFewLeft`, `nextAvailableDay`…).
- Label slot times with the server's business-local `slot.time` / `confirmation.time` via `formatClockTime`
  (never re-derive them from `startsAt` in the browser: browser and server time-zone data can disagree).
- Book in two steps: `requestBooking()` → code step → `verifyBooking()`. "Send a new code" =
  `resendVerificationCode()`; "Choose another time" = await `cancelBookingRequest()`, then reload availability.
- Handle `ok: false` on every call. Show success only after `verifyBooking()` returned `ok: true`
  (pending → "Request received — we'll confirm your appointment shortly.", confirmed → "Your appointment is booked.").
  Preview answers `PREVIEW_MODE`: say so honestly, never a success screen.
- `business.policies.onlineBookingEnabled === false` (or `BOOKING_DISABLED`) → contact details instead of the flow.
- The engine sends every booking email. Never add an email service to the website.
- Keep the packaged dashboard on `/admin/` (`admin/index.html` → `src/admin-main.tsx`). Never fork or restyle it:
  `src/admin-theme.css` sets only `--pbe-accent` / `--pbe-accent-text` per mode.

## What the engine does not do — never fake it

**One booking = one dog + one service, on one shared calendar (one table, one groomer at a
time).** A new booking feature needs a new engine version — never custom database code or
browser-side logic in this project:

- breed-, weight- or coat-based pricing (sizes are separate services named by size; the
  page's size picker only filters), add-on pricing or extras with prices, packages;
- several dogs in one booking, choosing a groomer, several tables or groomers' calendars;
- deposits, payments, tips, recurring appointments ("every 6 weeks"), subscriptions;
- pet profiles, vaccination or medical records, behaviour flags.

The groom card on the page describes the groomer's **own** notes — never say the website or
the booking system stores a dog's record. The booking notes field asks for a short note about
the dog (name, breed or size, coat condition, what helps) and says no medical records are
needed. Proposed engine work: `docs/ENGINE-PROPOSAL-pet-grooming.md` in the Niche Pack workspace.

## Where things live

| What | Where |
|---|---|
| Engine instance (preview: name, `America/Chicago`, placeholder contact) | `src/lib/engine.ts` |
| This site's preset (sample services, hours, policies; "clients"/"appointments") — also the dashboard's starter set | `src/lib/preset.ts` (`sitePreset`) |
| Kinds (from the name, then the description), sizes (from the name), "For:" parsing, name/size split, duration/price labels | `src/lib/services.ts` |
| What the owner can edit (texts, every section photo, the six gallery frames, the four step photos, the groom card, size ranges, logo, brand colour, heading style) | `src/content/site.ts` (`defineSiteContent`) |
| Content store + brand → CSS variables (`--accent`, `data-headings`) | `src/lib/content.ts` |
| Design tokens — the ONLY file with raw colours, fonts, sizes, spacing | `src/styles/tokens.css` |
| Base / page / booking styles (tokens only) | `src/styles/base.css`, `site.css`, `booking.css` |
| Sections | `src/components/*.tsx` (Header, Hero, GroomCard, Services, Gallery, Experience, Studio, GoodToKnow, Visit, Footer; `SectionMark` the numbered tab label; `Emphasis` renders the owner's `*highlight*` in the brand colour); the section list for header, phone menu and footer is `src/lib/nav.ts` |
| Booking sheet (a modal `<dialog>` at `#book`; Back/Esc/✕ close it) + the `#book` band | `src/App.tsx` (open/close + history), `src/components/booking/BookingSheet.tsx`, `BookingSection.tsx`, `src/lib/dialog.ts` |
| Booking flow | `src/components/booking/` (BookingFlow = state + engine calls, root `#book-flow`; DayPicker, TimePicker, DetailsForm, CodeStep, Summary, Done) |
| "Open now" + hours changes (from `getOpeningTimes`, fallback to weekly hours) | `src/lib/useOpening.ts`, `src/lib/hours.ts` |
| Photo variant map | `public/photos/`, `src/content/photoVariants.ts` (generated) |
| Content baked into `index.html` at build | `vite.config.ts` (`publishedSiteContent`) |

## Rules for future changes

- **Content fields:** render values as text (never `dangerouslySetInnerHTML`), images from the resolved
  `src`/`alt`. Never rename or reuse a field id on a live site — add a new id. Services, prices, durations,
  hours, the address, phone and email are NOT content: they come from the engine. The engine does not allow
  default images inside list fields — that is why each gallery frame (`gallery.photo1…6`) and each step's
  photo (`experience.step1Photo…4`) is its own image field.
- `src/content/site.ts` is also imported by `vite.config.ts` (Node): keep it free of local imports.
- **Every Book button** calls `startBooking()` (App): it opens the sheet, or — while online booking is off,
  unconfigured or failing — leads to the `#book` section and its contact details. Keep it that way for any
  new button. A service row's Book passes that service's engine id — never a hard-coded id.
- **Kinds and sizes:** the engine has no categories or sizes, and service ids are database UUIDs unknown at
  build time, so `kindOf()` reads the NAME (then the description) against `RULES` (first match wins:
  puppy → tidy → bath → full; no match → "More services"), and `sizesOf()` reads size words in the NAME.
  A new kind or keyword goes in `RULES` (and a note field in `site.ts`); keep
  `concepts/pet-grooming-groom-card/kinds.test.mjs` (Niche Pack workspace) passing. Never hard-code a
  service, duration, price or id on the page, and never compute a price from a size.
- **For:** who a service is for is the part of its description after "For:" (or "Suits:"), split at "·"
  (`splitDescription`). Never add a separate, hard-coded list.
- **Prices:** show the engine's price; "from" exactly when `priceFrom` is true. Wording about coat condition
  must stay honest: the studio confirms a request and says before the appointment if time or price changes.
- **Default photos:** add your own variants to `public/photos/` (the original downloads and their script are
  not part of this starter), keep the default `src` in `site.ts` equal to a key in `photoVariants.ts`, record
  the source in `PHOTOS.md`. If the first-screen default changes, update both `<link rel="preload">` in
  `index.html` (desktop and phone; `imagesizes` must match `HERO_SIZES` / `PHONE_CROP` in
  `src/components/Hero.tsx`) and `DEFAULT_HERO` there — the phone crop is shown only for the default photo.
- **Sample photos:** every section photo carries a "Sample" label until the owner replaces that field
  (`ownerFields`); the gallery and studio say the photographs are another studio's. Never present a stock
  photo as the studio's own space, groomer, client dog or work; never name a photographed person or dog;
  never pair photos of different dogs as a before-and-after; never invent a groomer's name, qualifications,
  certifications, awards, reviews, testimonials or veterinary claims.
- **Policies:** Good to know shows a "Sample policies" label until the owner edits `faq.items`.
- **Service photos** are the owner's (`service.image`, dashboard → Services; shown as a small thumb in the
  row). Never add stock pictures for single services.
- **Copy:** plain, warm, practical; "clients", "appointments", "your dog". No guaranteed outcomes, no medical
  advice (skin, ears, behaviour → "see your vet"), no scarcity pressure, no "best in town". Kind, safe
  handling over speed; matted coats are clipped short rather than painfully brushed out.
- **Style:** plain CSS with the tokens; no UI kit. Keep 44 px tap targets, visible focus, the
  `prefers-reduced-motion` path, and every text/background pair at 4.5:1 (see DESIGN.md). The brand colour is
  owner-editable: on the brand-colour band text is `--on-accent`; on navy use `--accent-glow`.
- **Composition:** editorial and left-aligned (DESIGN.md → Layout). New sections open with `.section-head`
  (SectionMark + h2 + intro). The groom card stays the one ornament.
- The public site stays one page (sections + in-page booking flow); no client-side path routes.

## Commands

```bash
npm run dev                              # http://localhost:5179 (preview mode without a backend)
npm run build                            # tsc -b && vite build (multi-page: / and /admin/)
npm run lint                             # oxlint (supabase/functions is ignored)
npm run dev:demo                         # the Live Demo: in-browser engine + dashboard, nothing sent
npm run build:demo                       # the public Live Demo build — never the production site
npx booking-engine doctor                # project check
npx booking-engine doctor --dist dist    # after a build: scans the output for secrets
```

Connecting a backend (Supabase, email) follows INTEGRATION.md §11 — only with the owner's go-ahead.
