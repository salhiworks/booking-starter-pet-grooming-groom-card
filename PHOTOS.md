# Photographs

Fourteen frames from thirteen free photographs on Pexels, downloaded into the project (never
hot-linked), cropped for their one use, given one shared light grade and exported as AVIF +
WebP at three widths by the Groom Card photo pipeline. **This starter ships only those
processed frames** — the original downloads and the pipeline script stay with the Niche Pack
workspace (`concepts/pet-grooming-groom-card/photo-pipeline/photos.mjs`), so the repository
never redistributes an unaltered copy. No image-generation tool was used.

**One studio, one series.** Every frame comes from a single series published on Pexels by
**Goochie Poochie Grooming**, a professional groomer in Burlington, Ontario, photographing
their own bright salon: white walls and roller blinds, a stainless-steel bathing tub, black
grooming tables, plants by the window. That gives the site one light, one room and one way of
working — coat checks, baths, drying, scissor work, nails, finished dogs and the tools —
across many coat types (spaniel feathering, curly Poodle coats, a Yorkie's clipper trim, a
Shih Tzu's drop coat). The shared grade is a touch less saturation and slightly firmer blacks
(so the salon's pink and teal accessories sit quietly on the cream page); nothing is
retouched.

They are the website's **defaults** (`src/content/site.ts`): the owner replaces each one in
the dashboard (Website). **They are another grooming studio's photographs, not Brindle's
groomers, client dogs, work or space** (Brindle is fictional): the people and dogs did not
visit the studio, are not named, and nothing implies endorsement. Every photo carries a
**"Sample"** label on the page until the owner replaces it; the gallery says "Example
photography from a grooming studio — not this studio's clients or its own work", and in the
Live Demo and preview the studio section says the room, the dogs and the photographs are
licensed stock images from another grooming studio.

Groomers are identifiable in some frames (a face in profile in the face trim, the bath and the
Poodle scissoring). The Pexels License allows this use but forbids implying that a person or
brand endorses a business, and forbids showing people in a bad light: the Sample labels and the
copy keep them as illustrations, alt texts only describe what is in the frame, and there are no
before-and-after pairs. Shirts carry no legible logo or name in the crops used (checked at full
size). Frames showing award rosettes on the salon wall were rejected.

| Use (content field) | Files (`public/photos/`) | Source page | Photographer | Licence |
|---|---|---|---|---|
| First screen — a golden spaniel sits calmly while the groomer trims round a front paw (`hero.photo`, 4:5) | `hero-paw-{800,1200,1600}` | https://www.pexels.com/photo/woman-trimming-dogs-nails-19145889/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| First screen on phones — the same frame, head to paw, 5:4 (art-directed crop of the default only) | `hero-paw-wide-{480,800,1200}` | https://www.pexels.com/photo/woman-trimming-dogs-nails-19145889/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| A groom · 1 Drop-off — brushing the ear feathering of a relaxed spaniel (`experience.step1Photo`) | `step-coat-{480,800,1200}` | https://www.pexels.com/photo/dog-groomer-brushing-a-dog-19145878/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| A groom · 2 In the tub — rinsing a curly-coated dog in a steel tub (`experience.step2Photo`) | `step-bath-{480,800,1200}` | https://www.pexels.com/photo/groomer-standing-and-washing-dog-19145897/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| A groom · 3 On the table — scissoring a black Standard Poodle’s topknot (`experience.step3Photo`) | `step-finish-{480,800,1200}` | https://www.pexels.com/photo/woman-grooming-a-poodle-19145899/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| A groom · 4 Collection — a freshly groomed Shih Tzu on the table (`experience.step4Photo`) | `step-home-{480,800,1200}` | https://www.pexels.com/photo/dog-getting-professional-haircut-19145876/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| Gallery 1 — face trim with curved scissors by the window (`gallery.photo1`) | `work-face-{800,1200,1600}` | https://www.pexels.com/photo/groomer-trimming-dog-19145886/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| Gallery 2 — a Poodle in a snood dried with a hose dryer (`gallery.photo2`) | `work-dry-{480,800,1200}` | https://www.pexels.com/photo/blow-drying-a-dog-19145873/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| Gallery 3 — a Yorkshire Terrier, clipper trim (`gallery.photo3`) | `work-clip-{480,800,1200}` | https://www.pexels.com/photo/a-dog-at-a-groomer-19145877/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| Gallery 4 — scissoring a brown Poodle’s legs (`gallery.photo4`) | `work-legs-{800,1200,1600}` | https://www.pexels.com/photo/dog-being-brushed-19145894/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| Gallery 5 — a nail trim (`gallery.photo5`) | `work-nails-{800,1200,1600}` | https://www.pexels.com/photo/dog-groomer-trimming-dogs-nails-19145872/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| Gallery 6 — tidying leg feathering with thinning scissors (`gallery.photo6`) | `work-feet-{800,1200,1600}` | https://www.pexels.com/photo/woman-hand-trimming-dog-19145880/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| The studio — a Standard Poodle sitting by the bathing tub, leads on the rail (`studio.photoRoom`) | `studio-tub-{800,1200,1600}` | https://www.pexels.com/photo/a-dog-in-a-pet-salon-19145874/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |
| The studio — clipper, scissors and thinning shears on the table (`studio.photoDetail`) | `studio-tools-{480,800,1200}` | https://www.pexels.com/photo/trimmer-and-scissors-for-grooming-19145890/ | Goochie Poochie Grooming ([@goochie-poochie](https://www.pexels.com/@goochie-poochie/)) | Pexels License |

Downloaded 2026-11-09 at 3200 px wide (`images.pexels.com/photos/<id>/pexels-photo-<id>.jpeg?w=3200`);
licence and photographer checked the same day on each photo page.

## Crops

Fractions of the original (`photo-pipeline/photos.mjs`):

- **First screen** 4:5 from 10 % down — the dog's head in the upper half, the paw and the
  groomer's hands in the lower third, the blinds at the left (where the groom card hangs on
  desktop). Phones (below 960 px): a 5:4 crop of the same frame from 17 % down, head to paw.
  An owner's own first-screen photo is used as it is on every screen.
- **Steps** 4:5: the coat check and the Shih Tzu cut from wide originals around the dog
  (25 % / 36 % across), the bath 24 % across (dog and the groomer's gloved hands), the Poodle
  from an upright original 12 % down.
- **Gallery**: the two uprights at 4:5 (6 % and 14 % down), the wide frames at 3:2 (the nail
  and feathering frames are 16:9 originals, cropped 8 % / 6 % across).
- **Studio**: the tub corner at its full 3:2; the tools 4:5 from 26 % across.

Total: 1.7 MB AVIF + 2.7 MB WebP across all widths; the first screen preloads its AVIF
(`index.html`), everything else loads lazily.

## Considered and not used

- **Pexels 19145900** (the same series, a wide view of the room with a Poodle on the table) —
  no public photo page any more, so its licence could not be confirmed.
- **Frames with award rosettes on the wall** (19145884, 19145893) — they would read as the
  fictional studio's awards.
- **A blue-wall Yorkshire Terrier series** (Pexels 6130995–6131580) — coherent and clean, but
  posed, one dog only, and a flat studio backdrop rather than a working room.
- **Garden and home-brushing photos** (white fluffy dogs on wooden floors, Samoyeds outdoors) —
  pretty, but not grooming work and a different light.
- **Show-ring and event grooming** (a Pomeranian on a show table, a show Cocker Spaniel) —
  crowds and a competition feel, not a calm studio.
- AI-generated dogs — not used: real coat texture and real handling matter for trust here.
