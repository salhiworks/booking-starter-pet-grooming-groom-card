# Groom Card — the visual system

**Idea:** a clean, calm grooming room in daylight, and the **groom card** — the record a
good groomer keeps for every dog: coat type and condition, clip length and finish, likes,
dislikes and handling notes, when the coat is due again. Owners booking a groom want three
things from the first screen: *my dog will be calm and safe here*, *they know coats*, and
*what will it cost for my dog's size*. The site answers in that order — a calm dog on the
table in soft window light, a promise about every coat, and a price list you can narrow to
your dog's size in one tap.

No pet-shop clichés: no paw prints, bones, cartoon dogs or random pastels; no clinical
whites or medical crosses (it is a grooming studio, not an animal hospital). Warmth comes
from the photography, the cream and oat grounds and a round, friendly serif; trust comes
from plain information, real prices with honest "from"s, and care standards stated simply.

Every raw value lives in `src/styles/tokens.css`. Other stylesheets use the tokens only.

## Colour

| Token | Value | Use | Contrast |
|---|---|---|---|
| `--accent` (owner: *Brand colour*) | `#2b4c9e` cobalt | Buttons, highlighted headline words, the chosen size tab, the booking band, the calendar selection, focus rings, the name mark's card | white on it 8.0:1 (the editor checks any new colour against `#ffffff` at 4.5:1); on the page 7.2:1 |
| `--accent-glow` | cobalt lifted towards pale blue | The brand colour on navy (footer name-mark card, focus on dark) | ≥ 7:1 on navy |
| `--paper` | `#f8f4ec` warm cream | The page | — |
| `--raised` | `#fffdf9` card white | Inputs, the booking sheet's panels, the groom card, the size tabs | — |
| `--oat` | `#efe7d8` oat | A groom (band), Good to know, the price note, the booking summary | muted text 5.6:1 |
| `--ink` / `--ink-soft` / `--muted` | `#1d2232` / `#343a4b` / `#5e5a52` | Text | 15 / 11 / 6.3:1 on the page |
| `--ply` (honey) | `#d9a45b` | Decorative only: the dot before labels, the groom card's ruled lines, the edge under the booking sheet's header, the underline of the price link | — |
| `--honey-wash` | `#f4e4c8` | The card's "Groom card" tab, section numbers, size tags on service names | ink on it 13:1 |
| `--forest` (navy) | `#1b2236` | The booking sheet's header, the footer | `--on-forest` 15:1 |
| `--clay` | `#a3261a` | Errors only, always with words | — |

Measured (rendered, Chromium, 1440 and 390 px, page + booking sheet,
`concepts/pet-grooming-groom-card/contrast.mjs` in the Niche Pack workspace): lowest text pair
**5.59:1**, none below 4.5.

Why cobalt: the photographs are full of golden and apricot coats on a black table under
white light; a deep blue is their complement, reads clean and trustworthy (water, tile, a
well-kept leash) without the clinical feel of teal or the nursery feel of pastels. Honey ties
back to the coats in small amounts only.

## Type

- **Young Serif** (one weight, OFL) for headlines, the name mark, step and kind titles —
  round, soft-edged and confident; friendly without being childish. 1.04 leading, −0.012em.
- **Figtree** (variable, OFL) for everything else; 400 body at 1.6, 600–700 for labels,
  names and prices; small labels in capitals at 0.12em; tabular figures for times and prices.
- **The highlight.** The owner's `*highlight*` in a headline is set in the brand colour (no
  italics). On the cobalt booking band it turns white with a honey underline.
- Heading style (owner): *Soft serif* (default) or *Clean sans* (Figtree 680).
- The name mark: "Brindle" in Young Serif beside a tiny cobalt **card** with a punched hole,
  "Grooming Studio" in small capitals under it (owner-editable descriptor; hidden ≤ 380 px).

## Devices (each with a job)

- **The groom card** (`GroomCard.tsx`). A cream index card — punched hole, a small "Groom card"
  tab, a serif title, four ruled lines with empty tick boxes, one sentence of note. It explains
  a real practice (the groomer's own notes, not the website's) and makes "we know your dog"
  concrete. Desktop: hung off the hero photo's lower-left corner, over the blinds, never over
  the dog, tilted 1.5°. Phones: after the facts. Owner-editable (title, lines, note; empty
  title hides it). It shows no real dog's details.
- **Index-card tabs.** The section numbers (honey-washed tabs), the dog-size picker and the
  size tags on service names share the card's language.
- **The punched hole.** A small honey dot before eyebrow labels.
- **The honey edge.** A 4 px honey line under the booking sheet's navy header.
- **Rounded photographs** (22 px) and pill buttons — soft, never bubbly.

Nothing else decorates the page.

## Layout

Editorial and left-aligned, with two columns on wide screens; every section answers one
question an owner has before booking.

1. **Header** — the name mark, six section links (Prices first), *Book a groom*; phones fold
   the links into a menu, Book always visible.
2. **First screen** — words left (eyebrow, headline, lede, *Book a groom* + *See prices by
   size ↓*, engine facts: full grooms from $X · N services · today's open status), the photo
   right at 4:5, never taller than the screen below the header (1280×720 → 620 px), the groom
   card over its corner. Phones: a 5:4 crop of the same moment (≤ 38 % of the screen, 31 % on
   short phones), then headline and **Book a groom before the lede**, so the button is inside
   the first screen even at 320×568 (526 px).
3. **01 Services & prices** — intro; *Your dog's size* tabs (All sizes · Small · Medium ·
   Large, with the owner's weight range on each; 2×2 on phones); kinds as rows: the kind's
   title and note on the left (sticky on desktop), its services on the right — name with a
   size tag, what it includes, *For* line, time booked, price ("from"), *Book →*. Choosing a
   size filters the rows (announced to screen readers); it never changes a price. Under the
   list, the owner's note about starting prices and coat condition.
4. **02 Gallery** — six frames of coat work with short captions (coat · work), in two
   justified rows on wide screens (each row one height, every photo whole); two columns on
   phones, wide frames across both. Labelled sample photography until replaced.
5. **03 A groom, start to finish** (oat band) — Drop-off · In the tub · On the table ·
   Collection, each with an upright photo, a numbered moment, a title and two or three
   sentences. Four columns on desktop, two on tablets, photo-beside-text on phones.
6. **04 The studio** — the room wide with the tools overlapping its corner, two paragraphs,
   four care standards with a cobalt dot.
7. **05 Good to know** (oat) — heading left (sticky) with the *Sample policies* label until
   the owner edits the answers; questions right as native disclosures.
8. **Booking band** (brand colour) — *Book a groom*, three steps (demo-true wording), a white
   button; contact details instead while booking is off.
9. **06 Visit** — hours with today marked, open status, contact, drop-off & collection.
10. **Footer** (navy) — the name mark large, sections, contact, Staff login.

## Booking sheet

The shared booking flow, unchanged in logic, in a cream sheet with a navy header edged in
honey (full screen on phones, a wide panel from the right from 960 px). Step 1 groups
services in the page's kinds with size tags, the time booked, the price and the *For* line.
The summary names the service, *Booked for*, the price — with "A starting price — confirmed
before the day" when the engine says `priceFrom` (hidden in the phone strip to keep it to one
line) — and the date and time. The notes field asks *About your dog (optional)* — name, breed
or size, coat condition, how you'd like them to look, anything that helps — and says no
medical records are needed. The success screen for a request adds: if the coat needs more
time or a different price, we tell you before the appointment.

## Motion

Only on the first screen: the photo settles (scale 1.035 → 1), the words rise in a short
stagger, the card drops in. Everything else is still. `prefers-reduced-motion` removes it all.

## Accessibility

44 px targets throughout (size tabs 56 px), visible focus rings in the brand colour (white on
the band, cream on navy), size tabs as `aria-pressed` buttons in a labelled group with a live
count, kinds as labelled sections, disclosures for questions, the sheet a modal `<dialog>`
(Esc, Back, ✕), skip link, no horizontal overflow from 320 px.
