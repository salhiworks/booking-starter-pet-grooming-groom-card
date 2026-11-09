# Pet Grooming Studio Booking Website — "Groom Card" Starter

A finished, premium booking website for an independent dog grooming studio, ready to
make your own with Claude Code and publish on Hostinger. It ships as **Brindle Grooming
Studio**, a fictional, one-dog-at-a-time grooming studio in Linden Hills, Minneapolis:

- a one-page studio website — a first screen with a calm dog on the grooming table in
  daylight, a round, friendly serif headline, one Book button, a link to the prices and the
  **groom card** (the notes a good groomer keeps for every dog) hung off the photo's corner;
  services and prices with a **dog-size picker** (All · Small · Medium · Large, drawn as
  index-card tabs), grouped as Full grooms, Baths & coat care, Puppies, and Tidies & nails —
  each with what it includes, who it is for, the time the dog is booked in and the price
  ("from" when it is a starting price); a six-frame gallery of coat work; a groom start to
  finish in four photographed steps; the studio and its care standards; *Good to know*
  (sample policies, labelled); drop-off and collection details — from 320 px phones up, with
  booking in a sheet over the page;
- online booking — one dog and one service per booking, a day and drop-off time, contact
  details and an optional note about the dog (name, breed or size, coat condition, what
  helps), and an emailed 6-digit code; the studio confirms each request and says before the
  day if the coat needs more time or a different price;
- the owner dashboard at `/admin/` — requests to confirm, services and prices, opening hours
  and closures, email health, and the website's own text, photos, brand colour and heading
  style.

The look — *Groom Card*: a clean, calm grooming room in daylight. Warm cream and oat
grounds, navy ink, honey for small edges, one brand colour (cobalt by default) for
everything you can press; Young Serif headlines over Figtree; soft, card-stock corners.

Booking runs on [`@profitstudio/booking-engine`](https://www.npmjs.com/package/@profitstudio/booking-engine)
**2.0.0-beta.3** (pinned) with your own Supabase project and Resend for email.

## 1. Try it (no accounts needed)

```bash
npm install
npm run dev:demo   # the full Live Demo: book, then manage it at /admin/
npm run dev        # preview mode: the website with sample times, nothing saved
```

In the Live Demo everything stays in your browser — nothing is sent anywhere.

## 2. Make it yours with Claude Code

Open this folder in a Claude Code session and paste the prompt in
[`CUSTOMIZE.md`](CUSTOMIZE.md), filled in with your studio. Claude edits a short list of
files (name, city, words, colours) — the booking system, the dashboard and the layout stay
as they are, so it is quick and cheap.

Services, prices, opening hours and contact details are **not** code: you set them in the
dashboard once the booking backend is connected. **Your own photographs** — the first
screen, the six gallery frames, the four steps of a groom and the studio — go in the
dashboard → Website; each sample photo stays labelled "Sample" until you replace it.
Groomers' names and qualifications are yours to add: the starter invents none.

**One table, one calendar.** The booking engine keeps one shared calendar, so the site only
offers times when the studio is free, one dog at a time, and a service's length is the time
the dog is booked in (drop-off to collection). **Size pricing works by name:** each size of a
full groom or bath is its own service ("Full Groom — Small Dog"); the size picker on the page
only filters the list. Breed or weight pricing, several dogs in one booking, choosing a
groomer, several tables, add-on pricing, deposits, pet records and recurring appointments are
not part of the engine (see *What the engine does not do* in `CLAUDE.md`).

## 3. Connect real bookings

You need a free Supabase project and a Resend account for booking emails.

```bash
cp .env.example .env.local    # your Supabase Project URL + Publishable key
npx supabase@2 login          # once, in your own terminal
npx booking-engine connect --admin you@example.com
```

`connect` links the project, sets up the database and the booking-email function, and tells
you exactly what is left for you to do (your dashboard login and the two email secrets).
Full steps: the Profit Studio guide *Build a Premium Booking Website with Claude Code*,
Step 3, or `node_modules/@profitstudio/booking-engine/docs/INTEGRATION.md` §11.

Never put a Supabase **Secret** key or your Resend API key in `.env.local`, in a prompt or in
Hostinger — the Resend key lives only in Supabase's Edge Function secrets.

## 4. Publish on Hostinger

Push this project to a private GitHub repository, then in Hostinger create a **Web App**
from it (Websites → Create site → Web App → Import Git Repository):

| Setting | Value |
|---|---|
| Framework | Vite |
| Build command | `npm run build` (never `build:demo`) |
| Output directory | `dist` |
| Node.js | 22 or newer |
| Environment variables | `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` (public values only) |

`dist/` contains the website and `dist/admin/` the dashboard. Every push to `main` redeploys.

## What is in this folder

| | |
|---|---|
| `src/site.config.ts` | The business name, time zone and preview contact details |
| `src/content/site.ts` | Everything the owner can edit in the dashboard → Website, with its default text and photos |
| `src/styles/tokens.css` | The design's colours, type and spacing (one file); `DESIGN.md` explains the system |
| `src/components/` | The website (`Hero`, `GroomCard`, `Services`, `Gallery`, `Experience`, `Studio`, `GoodToKnow`, `Visit`…) and its booking flow (`src/components/booking/`) |
| `src/lib/preset.ts` | The sample services and hours used by preview mode and offered in a new dashboard |
| `src/lib/services.ts` | How services find their kind and dog size (by the words in their names) and who they are for (from "For:" in the description) |
| `admin/` + `src/admin-main.tsx` | The packaged dashboard, mounted at `/admin/` |
| `src/demo/` | The Live Demo's in-browser engine and sample data — used only by `dev:demo` / `build:demo`; a normal build contains none of it |
| `supabase/` | The engine's database migrations and email function (managed by `npx booking-engine`; do not edit) |
| `CLAUDE.md`, `BOOKING_ENGINE.md` | Rules Claude Code follows in this project |
| `PHOTOS.md`, `ASSETS.md` | The Pexels photos (Pexels License), credited file by file |

## Commands

```bash
npm run dev          # preview mode (sample data) until .env.local exists — http://localhost:5179
npm run dev:demo     # the Live Demo (in-browser data, dashboard included)
npm run build        # production build → dist/
npm run build:demo   # the public Live Demo build → dist/ (never deploy this as your site)
npx booking-engine doctor             # checks versions, engine files and keys
npx booking-engine doctor --dist dist # after a build: also scans the output for secrets
```

## Licence

The code is MIT-licensed — see [`LICENSE`](LICENSE) (Copyright (c) 2026 Youssef Es-salhi).
Photographs and other third-party assets keep their own terms, listed file by file in
[`ASSETS.md`](ASSETS.md).
