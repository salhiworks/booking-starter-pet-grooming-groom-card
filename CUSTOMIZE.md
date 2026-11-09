# Make this starter yours — the Claude Code prompt

Fill in the four lines at the top, then paste the whole prompt into a Claude Code session
opened in this folder. It changes identity and words only, so it finishes in one short
session.

```text
Customize this dog grooming studio starter for my business.

Studio name: <YOUR STUDIO NAME>
City and area: <CITY, AREA>
Time zone (IANA): <e.g. America/Chicago>
How we groom, which dogs we see, and our personality in a few words: <e.g. small and medium dogs, calm and unhurried, doodles a speciality>

Follow CLAUDE.md (already loaded in this session — no need to open it again).
Open and change only these files; don't explore the rest of the project:
1. src/site.config.ts — name, timezone, and fictional previewContact details in my city.
2. index.html and admin/index.html — the studio name, city and description in <title>,
   the meta description and the og tags.
3. src/content/site.ts — rewrite every DEFAULT text for my studio: the name mark
   (brand.wordmark — one short word) and the line under it, the line above the headline,
   headline, introduction, the groom card's title, lines and note, the services intro, the
   dog-size ranges and the line under them, the four kind notes, the note about prices, the
   gallery intro and captions, the four steps of a groom, the studio text and facts, Good to
   know answers (my real policies), the drop-off note and the search title and description.
   Keep field ids, types, limits and photos. Keep the sample photos (they stay labelled
   "Sample" until I upload my own). Headlines may set one or two words in the brand colour
   with *asterisks* — keep that style.
4. Only if cobalt clearly doesn't fit my studio (otherwise skip this step and don't open
   these files): change the default of brand.accent in src/content/site.ts (a deep colour —
   deep teal, plum, forest, brick), the light-mode colour in src/admin-theme.css and the card
   in public/favicon.svg, keeping white text at 4.5:1 on it.

Do not change the layout, the booking flow, src/lib/engine.ts, src/lib/preset.ts,
src/lib/services.ts, src/demo/, supabase/, booking-engine.lock.json or package.json.
Do not invent services, prices, opening hours, groomers' names, qualifications or
certifications, awards, reviews, testimonials, veterinary or medical claims, or
before-and-after photos I have not given — services, prices and hours are set in the
dashboard. When done, run npm run build and fix any error, then show me the result with
npm run dev.
```

## After the prompt

- **Your services:** dashboard → Services. One service is one dog and one appointment.
  - **Kinds.** The page sorts services by the words in their names, checked in this order:
    *puppy / first groom / introduction* → **Puppies**; *nail / tidy / face / feet / paw /
    hygiene / ears* → **Tidies & nails**; *bath / wash / brush / deshedding / blow-out /
    undercoat* → **Baths & coat care**; *groom / haircut / clip / scissor / trim / style* →
    **Full grooms**. A name with none of these is sorted by its description, otherwise it
    appears under "More services".
  - **Dog sizes.** Put the size in the name after a dash: `Full Groom — Small Dog`,
    `Bath & Brush — Small & Medium Dog`, `Full Groom — Large Dog`. The size picker on the page
    then filters by it; a service without a size word (Nail Trim) shows for every size. Set
    the weight ranges on the tabs in Website → Services & prices.
  - **Starting prices.** Switch on **Starting price** in the service when coat condition can change it;
    the page and the booking then say "from $85", and the booking summary says it is
    confirmed before the day.
  - **Time.** A service's length is how long the dog is booked in, drop-off to collection;
    the buffer after it is your clean-down time.
- **Who a service is for:** end its description with `For:` and the items separated by `·` —
  for example `For: Shih Tzus, Yorkies · a fresh coat between grooms`.
- **Your photographs:** dashboard → Website → Welcome (one upright photo), Gallery (six
  frames: two upright, four wide — your own work only, and never two different dogs shown as
  a before and after), A groom, start to finish (four upright photos), The studio (a wide
  photo of the room and an upright detail). Remove a photo to show the section without it.
  Each stays labelled "Sample" until you replace it.
- **Policies:** Good to know is labelled "Sample policies" until you edit it — write your own
  cancellation, late-arrival, matting and puppy rules.
- **Groomers:** add names, experience and qualifications in your own words — for example in
  *The studio* text or its facts. Only state what you can show.
- Connect real bookings: README.md, step 3.
