# Assets and their terms

The code in this repository is MIT-licensed (`LICENSE`). The assets below are not: each keeps
its own terms.

## Photographs — Pexels License

Fourteen frames from thirteen Pexels photographs by one photographer, downloaded into the
project (never hot-linked), then cropped, graded once for the whole set and exported for their
frames. Only the processed frames are in this repository. They are sample imagery from another
grooming studio: nobody shown works at or endorses the (fictional) studio, no dog shown is its
client, and none of it is the studio's space or work. Full details and crops: `PHOTOS.md`.

| Files (`public/photos/`) | Source | Photographer | Licence (checked 2026-11-09) |
|---|---|---|---|
| `hero-paw-{800,1200,1600}.{avif,webp}` | [Pexels 19145889](https://www.pexels.com/photo/woman-trimming-dogs-nails-19145889/) | Goochie Poochie Grooming | Pexels License |
| `hero-paw-wide-{480,800,1200}.{avif,webp}` | [Pexels 19145889](https://www.pexels.com/photo/woman-trimming-dogs-nails-19145889/) | Goochie Poochie Grooming | Pexels License |
| `step-coat-{480,800,1200}.{avif,webp}` | [Pexels 19145878](https://www.pexels.com/photo/dog-groomer-brushing-a-dog-19145878/) | Goochie Poochie Grooming | Pexels License |
| `step-bath-{480,800,1200}.{avif,webp}` | [Pexels 19145897](https://www.pexels.com/photo/groomer-standing-and-washing-dog-19145897/) | Goochie Poochie Grooming | Pexels License |
| `step-finish-{480,800,1200}.{avif,webp}` | [Pexels 19145899](https://www.pexels.com/photo/woman-grooming-a-poodle-19145899/) | Goochie Poochie Grooming | Pexels License |
| `step-home-{480,800,1200}.{avif,webp}` | [Pexels 19145876](https://www.pexels.com/photo/dog-getting-professional-haircut-19145876/) | Goochie Poochie Grooming | Pexels License |
| `work-face-{800,1200,1600}.{avif,webp}` | [Pexels 19145886](https://www.pexels.com/photo/groomer-trimming-dog-19145886/) | Goochie Poochie Grooming | Pexels License |
| `work-dry-{480,800,1200}.{avif,webp}` | [Pexels 19145873](https://www.pexels.com/photo/blow-drying-a-dog-19145873/) | Goochie Poochie Grooming | Pexels License |
| `work-clip-{480,800,1200}.{avif,webp}` | [Pexels 19145877](https://www.pexels.com/photo/a-dog-at-a-groomer-19145877/) | Goochie Poochie Grooming | Pexels License |
| `work-legs-{800,1200,1600}.{avif,webp}` | [Pexels 19145894](https://www.pexels.com/photo/dog-being-brushed-19145894/) | Goochie Poochie Grooming | Pexels License |
| `work-nails-{800,1200,1600}.{avif,webp}` | [Pexels 19145872](https://www.pexels.com/photo/dog-groomer-trimming-dogs-nails-19145872/) | Goochie Poochie Grooming | Pexels License |
| `work-feet-{800,1200,1600}.{avif,webp}` | [Pexels 19145880](https://www.pexels.com/photo/woman-hand-trimming-dog-19145880/) | Goochie Poochie Grooming | Pexels License |
| `studio-tub-{800,1200,1600}.{avif,webp}` | [Pexels 19145874](https://www.pexels.com/photo/a-dog-in-a-pet-salon-19145874/) | Goochie Poochie Grooming | Pexels License |
| `studio-tools-{480,800,1200}.{avif,webp}` | [Pexels 19145890](https://www.pexels.com/photo/trimmer-and-scissors-for-grooming-19145890/) | Goochie Poochie Grooming | Pexels License |

**Terms.** Pexels License (https://www.pexels.com/license/): free to use and modify,
commercially or not; no selling unaltered copies; no redistribution on other stock-photo or
wallpaper platforms; no implying endorsement by people or brands shown; no portraying
identifiable people in a bad light. **If you build your own studio's site from this starter,
replace these with photographs of your own studio, your own work and (with their owners'
consent) your clients' dogs.**

## Not in this repository (installed by `npm install`)

| Package | Licence | Notes |
|---|---|---|
| `@profitstudio/booking-engine` 2.0.0-beta.3 | MIT | The booking engine and the packaged dashboard |
| `react`, `react-dom` | MIT | |
| `@fontsource/young-serif` | OFL-1.1 | Typeface (Young Serif — The Young Serif Project Authors, github.com/noirblancrouge/YoungSerif) |
| `@fontsource-variable/figtree` | OFL-1.1 | Typeface (Figtree — The Figtree Project Authors, github.com/erikdkennedy/figtree) |

Fonts are bundled into your build by Vite; the SIL Open Font License 1.1 allows that (keep the
fonts' licence files in `node_modules` — no action needed).

## Original work (MIT, see LICENSE)

- `public/favicon.svg` — drawn in SVG for this starter (a cobalt groom card with a punched hole
  and ruled lines).
- Every ornament that is code: the groom card (`src/components/GroomCard.tsx` + CSS), the name
  mark's card, the index-card section tabs and size tabs, the honey edge under the booking
  sheet's header.
- The brand "Brindle Grooming Studio", its copy and its address are fictional, made for this
  starter; the `.example` addresses and `555` phone numbers are reserved for examples.
