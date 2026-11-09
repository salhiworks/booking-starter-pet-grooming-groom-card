import { defineSiteContent } from '@profitstudio/booking-engine';

/**
 * What the owner may change in the dashboard (Website). The defaults are the
 * website's own copy and photos: until the owner publishes, the page shows
 * exactly these. Services, prices, durations, hours, the address, phone and
 * email are NOT here — they come from the engine.
 *
 * Never rename or reuse a field id once the site is live: the owner's text is
 * stored under it. Add a new id instead.
 *
 * This file is also imported by vite.config.ts (Node), so it imports nothing
 * local. Default photo `src` values are keys of src/content/photoVariants.ts.
 */
const MARK_HELP = 'Wrap a few words in *asterisks* to set them in your brand colour.';
const SAMPLE_HELP = 'A “Sample” label stays on it until you replace it with a photo of your own studio or your own work.';

/** The gallery's six frames: shape, default photo and caption. Each is its own field (no default images inside lists). */
const GALLERY = [
  {
    n: 1,
    shape: 'landscape',
    src: '/photos/work-face-1200.webp',
    alt: 'By a bright window, a groomer in glasses holds a small terrier mix’s muzzle and trims around its eyes with curved scissors.',
    caption: 'Face trim — clear eyes, soft muzzle',
  },
  {
    n: 2,
    shape: 'portrait',
    src: '/photos/work-dry-800.webp',
    alt: 'A grey Standard Poodle stands in the bathing tub wearing a snood over its ears while a groomer dries its curly coat with a hose dryer.',
    caption: 'Curly coat — dried straight, ears protected',
  },
  {
    n: 3,
    shape: 'portrait',
    src: '/photos/work-clip-800.webp',
    alt: 'A Yorkshire Terrier sits on the grooming table as a groomer steadies its chin and holds a clipper above its head.',
    caption: 'Short trim — clipper body, scissored legs',
  },
  {
    n: 4,
    shape: 'landscape',
    src: '/photos/work-legs-1200.webp',
    alt: 'Close-up of a groomer scissoring the legs of a brown Poodle standing on a table covered in clipped curls.',
    caption: 'Poodle legs — scissored to an even column',
  },
  {
    n: 5,
    shape: 'landscape',
    src: '/photos/work-nails-1200.webp',
    alt: 'A groomer holds up a golden dog’s front paw and trims a nail with small clippers.',
    caption: 'Nails — clipped short, edges smoothed',
  },
  {
    n: 6,
    shape: 'landscape',
    src: '/photos/work-feet-1200.webp',
    alt: 'A groomer’s hand with thinning scissors tidies the feathering on the front legs of a golden dog.',
    caption: 'Feathering — tidied, never taken off',
  },
] as const;

const GALLERY_SIZE = { portrait: { width: 800, height: 1000, ratio: 4 / 5 }, landscape: { width: 1200, height: 800, ratio: 3 / 2 } } as const;

/** The four steps of a groom: each with its own photo field. */
const STEPS = [
  {
    n: 1,
    when: 'Drop-off',
    title: 'Hello, and a look at the coat',
    text: 'We say hello, feel through the coat for knots and sore spots, and agree the length and finish with you. If the coat needs more time than booked, you hear it now — with the price — before we start.',
    src: '/photos/step-coat-800.webp',
    alt: 'A groomer brushes the long ear feathering of a relaxed golden spaniel, who sits on the table with its eyes closed.',
  },
  {
    n: 2,
    when: 'In the tub',
    title: 'Bath and a careful dry',
    text: 'A warm bath with a shampoo chosen for the coat, then a dry at the speed your dog is happy with. Curly and double coats are dried right through — the step that makes the finish last.',
    src: '/photos/step-bath-800.webp',
    alt: 'In a stainless-steel tub, a groomer in pink gloves rinses a wet, curly-coated dog held on a short lead.',
  },
  {
    n: 3,
    when: 'On the table',
    title: 'The trim and the finish',
    text: 'Clipper work where it suits the coat, scissors where it shows: face, feet, legs and outline. Nails and ears are done on every full groom. Breaks whenever your dog needs one.',
    src: '/photos/step-finish-800.webp',
    alt: 'A groomer scissors the topknot of a black Standard Poodle standing on a grooming table by a sunny window.',
  },
  {
    n: 4,
    when: 'Collection',
    title: 'Home, with a note',
    text: 'We text when your dog is ready, show you what we did, and tell you how to keep the coat between visits — and when it will be due again. It all goes on the groom card for next time.',
    src: '/photos/step-home-800.webp',
    alt: 'A freshly groomed Shih Tzu stands on the table with a neat, short body and a rounded face, looking at the camera.',
  },
] as const;

export const siteContent = defineSiteContent({
  sections: [
    {
      id: 'brand',
      label: 'Brand',
      description: 'Your name mark or logo, the brand colour and the heading style.',
      fields: [
        {
          type: 'text',
          id: 'brand.wordmark',
          label: 'Name mark',
          help: 'The short name in the header and footer. One short word reads best.',
          default: 'Brindle',
          maxLength: 20,
          required: true,
        },
        {
          type: 'text',
          id: 'brand.descriptor',
          label: 'Line under the name mark',
          help: 'What you are, in two or three words. Shown small under the name in the header.',
          default: 'Grooming Studio',
          maxLength: 28,
        },
        {
          type: 'image',
          id: 'brand.logo',
          label: 'Logo',
          help: 'Optional. A wide, dark logo on a transparent background — the header is a warm cream. It replaces the name mark in the header.',
          default: null,
          aspectRatio: 4,
        },
        {
          type: 'color',
          id: 'brand.accent',
          label: 'Brand colour',
          help: 'Buttons, highlighted words, the size tabs and the booking calendar. A deep colour — cobalt, deep teal, plum, forest — suits the design; white text must stay readable on it.',
          default: '#2b4c9e',
          contrastWith: '#ffffff',
          minContrast: 4.5,
        },
        {
          type: 'choice',
          id: 'brand.headings',
          label: 'Heading style',
          default: 'serif',
          options: [
            { value: 'serif', label: 'Soft serif', description: 'Round, friendly serif headings — the original design.' },
            { value: 'sans', label: 'Clean sans', description: 'The same layout with crisp sans-serif headings.' },
          ],
        },
      ],
    },
    {
      id: 'seo',
      label: 'Search & sharing',
      description: 'Search engines and link previews show new text after the website is next deployed.',
      fields: [
        {
          type: 'text',
          id: 'seo.title',
          label: 'Page title',
          help: 'Search engines and link previews show new text after the website is next deployed.',
          default: 'Brindle Grooming Studio — dog grooming in Linden Hills, Minneapolis',
          maxLength: 70,
          required: true,
        },
        {
          type: 'longText',
          id: 'seo.description',
          label: 'Page description',
          help: 'One or two sentences for search results. Updated after the next deploy.',
          default:
            'A calm, one-dog-at-a-time grooming studio in Linden Hills, Minneapolis. Full grooms, baths, deshedding, puppy introductions and nail trims — see prices by size and book online.',
          maxLength: 180,
          rows: 3,
          required: true,
        },
      ],
    },
    {
      id: 'hero',
      label: 'Welcome',
      description: 'The first screen: the headline, the buttons, one photo and the groom card beside it.',
      fields: [
        {
          type: 'text',
          id: 'hero.eyebrow',
          label: 'Small line above the headline',
          default: 'Dog grooming · Linden Hills, Minneapolis',
          maxLength: 64,
        },
        { type: 'text', id: 'hero.title', label: 'Headline', help: MARK_HELP, default: 'Calm grooming for *every coat.*', maxLength: 48, required: true },
        {
          type: 'longText',
          id: 'hero.lede',
          label: 'Introduction',
          default:
            'A small daylight studio with one dog on the table at a time. A proper bath and dry, a trim that suits the coat, and all the time your dog needs to feel at ease.',
          maxLength: 240,
          rows: 3,
        },
        { type: 'text', id: 'hero.cta', label: 'Main button', default: 'Book a groom', maxLength: 28, required: true },
        {
          type: 'text',
          id: 'hero.pricesLabel',
          label: 'Second link',
          help: 'Leads to the price list. Leave empty to hide it.',
          default: 'See prices by size',
          maxLength: 32,
        },
        {
          type: 'image',
          id: 'hero.photo',
          label: 'Main photo',
          help: `Upright (4:5) — a calm dog on the table works best, with its head in the upper half of the frame. ${SAMPLE_HELP}`,
          default: {
            src: '/photos/hero-paw-1200.webp',
            alt: 'A golden spaniel with long, freshly brushed ears sits calmly on a grooming table while a groomer trims around one front paw, daylight blinds behind.',
            width: 1200,
            height: 1500,
          },
          aspectRatio: 4 / 5,
        },
        {
          type: 'text',
          id: 'hero.cardTitle',
          label: 'Groom card — title',
          help: 'The card beside the photo describes the notes you keep for every dog. Leave empty to hide the card.',
          default: 'Every dog gets a groom card',
          maxLength: 40,
        },
        {
          type: 'list',
          id: 'hero.cardItems',
          label: 'Groom card — lines',
          itemLabel: 'Line',
          maxItems: 5,
          fields: [{ type: 'text', id: 'text', label: 'Line', default: '', maxLength: 40, required: true }],
          default: [{ text: 'Coat type & condition' }, { text: 'Clip length & finish' }, { text: 'Likes, dislikes & handling' }, { text: 'When the coat is due again' }],
        },
        {
          type: 'text',
          id: 'hero.cardNote',
          label: 'Groom card — note',
          default: 'Kept by your groomer, so every visit starts where the last one ended.',
          maxLength: 90,
        },
      ],
    },
    {
      id: 'services',
      label: 'Services & prices',
      description:
        'Service names, lengths and prices come from Services in this dashboard. The page sorts them by the words in their names (full groom → Full grooms; bath, brush or deshedding → Baths & coat care; puppy → Puppies; nails, face, feet or tidy → Tidies & nails) and reads the dog size from the name (“— Small Dog”, “— Medium Dog”, “— Large Dog”, “— Small & Medium Dog”). End a description with “For:” and items separated by “·” to show who a service is for.',
      fields: [
        { type: 'text', id: 'services.title', label: 'Title', help: MARK_HELP, default: 'Grooms & *prices*', maxLength: 48, required: true },
        {
          type: 'longText',
          id: 'services.intro',
          label: 'Introduction',
          default: 'One dog, one service per appointment. Choose your dog’s size to see the right prices — times are how long we book your dog in, from drop-off to collection.',
          maxLength: 320,
          rows: 3,
        },
        { type: 'text', id: 'sizes.small', label: 'Small dogs are…', help: 'Shown on the Small tab.', default: 'up to 20 lb', maxLength: 24 },
        { type: 'text', id: 'sizes.medium', label: 'Medium dogs are…', help: 'Shown on the Medium tab.', default: '21–50 lb', maxLength: 24 },
        { type: 'text', id: 'sizes.large', label: 'Large dogs are…', help: 'Shown on the Large tab.', default: '51–90 lb', maxLength: 24 },
        {
          type: 'text',
          id: 'sizes.note',
          label: 'Line under the sizes',
          default: 'Over 90 lb or a giant breed? Call us and we’ll plan the time together.',
          maxLength: 120,
        },
        {
          type: 'longText',
          id: 'services.noteFull',
          label: 'Note beside “Full grooms”',
          default: 'Bath, dry, a full haircut, nails and ears — priced by size.',
          maxLength: 200,
          rows: 2,
        },
        {
          type: 'longText',
          id: 'services.noteBath',
          label: 'Note beside “Baths & coat care”',
          default: 'A fresh, fully dried coat without a haircut — and help for heavy shedders.',
          maxLength: 200,
          rows: 2,
        },
        {
          type: 'longText',
          id: 'services.notePuppy',
          label: 'Note beside “Puppies”',
          default: 'A short, kind first visit, so grooming feels ordinary from the start.',
          maxLength: 200,
          rows: 2,
        },
        {
          type: 'longText',
          id: 'services.noteTidy',
          label: 'Note beside “Tidies & nails”',
          default: 'Quick visits between full grooms.',
          maxLength: 200,
          rows: 2,
        },
        {
          type: 'longText',
          id: 'services.priceNote',
          label: 'About prices',
          help: 'Shown under the list. Keep it honest about starting prices and coat condition.',
          default:
            'Prices marked “from” are for a coat in reasonable, brushed condition. Matting, a very thick coat or a big change of style takes longer: we read every request, and if your dog needs more time or a different price we tell you before the appointment — never after.',
          maxLength: 400,
          rows: 4,
        },
      ],
    },
    {
      id: 'gallery',
      label: 'Gallery',
      description:
        'Six frames of grooming work. Each sample photo carries a “Sample” label until you replace it — always show your own work, and never show two different dogs as a before and after. Remove a photo to show fewer.',
      fields: [
        { type: 'text', id: 'gallery.title', label: 'Title', help: MARK_HELP, default: 'From the grooming *table*', maxLength: 48, required: true },
        {
          type: 'longText',
          id: 'gallery.intro',
          label: 'Introduction',
          default: 'Curly, silky, wiry and double coats each need their own care. A few of the details that make a groom last.',
          maxLength: 240,
          rows: 2,
        },
        ...GALLERY.flatMap((g) => [
          {
            type: 'image' as const,
            id: `gallery.photo${g.n}` as const,
            label: `Photo ${g.n} (${g.shape === 'portrait' ? 'upright' : 'wide'})`,
            help: `${g.shape === 'portrait' ? 'Upright (4:5)' : 'Wide (3:2)'}. ${SAMPLE_HELP}`,
            default: { src: g.src, alt: g.alt, width: GALLERY_SIZE[g.shape].width, height: GALLERY_SIZE[g.shape].height },
            aspectRatio: GALLERY_SIZE[g.shape].ratio,
          },
          {
            type: 'text' as const,
            id: `gallery.caption${g.n}` as const,
            label: `Caption ${g.n}`,
            help: 'What the photo shows, in a few words — the coat and the work. Leave empty for none.',
            default: g.caption,
            maxLength: 64,
          },
        ]),
      ],
    },
    {
      id: 'experience',
      label: 'A groom, start to finish',
      description: 'The four parts of an appointment, each with a photo.',
      fields: [
        { type: 'text', id: 'experience.title', label: 'Title', help: MARK_HELP, default: 'A groom, *start to finish*', maxLength: 60, required: true },
        {
          type: 'longText',
          id: 'experience.intro',
          label: 'Introduction',
          default: 'What happens between drop-off and collection — so you and your dog know what to expect.',
          maxLength: 240,
          rows: 2,
        },
        ...STEPS.flatMap((s) => [
          { type: 'text' as const, id: `experience.step${s.n}When` as const, label: `Step ${s.n} — small label`, default: s.when, maxLength: 24 },
          { type: 'text' as const, id: `experience.step${s.n}Title` as const, label: `Step ${s.n} — title`, default: s.title, maxLength: 48, required: true },
          { type: 'longText' as const, id: `experience.step${s.n}Text` as const, label: `Step ${s.n} — text`, default: s.text, maxLength: 320, rows: 4 },
          {
            type: 'image' as const,
            id: `experience.step${s.n}Photo` as const,
            label: `Step ${s.n} — photo (upright)`,
            help: `Upright (4:5). Remove it to show the step without a photo. ${SAMPLE_HELP}`,
            default: { src: s.src, alt: s.alt, width: 800, height: 1000 },
            aspectRatio: 4 / 5,
          },
        ]),
      ],
    },
    {
      id: 'studio',
      label: 'The studio',
      description: 'The room, your tools and how you work. Two photos and a few plain facts — no awards or certificates unless they are really yours.',
      fields: [
        { type: 'text', id: 'studio.title', label: 'Title', help: MARK_HELP, default: 'A small studio, *one dog at a time*', maxLength: 60, required: true },
        {
          type: 'longText',
          id: 'studio.text',
          label: 'Text',
          default:
            'Brindle is a single bright room on Upton Avenue: one bathing tub, one grooming table and one dog at a time — so there is no barking crate room and no waiting in a line of dogs.\n\nWe groom by appointment, at your dog’s pace. Tables, tubs and tools are cleaned between every dog, blades are kept sharp, and nobody is ever left alone on a table or in a dryer.',
          maxLength: 900,
          rows: 7,
        },
        {
          type: 'image',
          id: 'studio.photoRoom',
          label: 'Photo of the studio (wide)',
          help: `The room itself, wide (3:2). ${SAMPLE_HELP}`,
          default: {
            src: '/photos/studio-tub-1200.webp',
            alt: 'A grey Standard Poodle sits calmly beside a stainless-steel bathing tub in a bright white grooming room, leads hanging on a rail behind it.',
            width: 1200,
            height: 800,
          },
          aspectRatio: 3 / 2,
        },
        {
          type: 'image',
          id: 'studio.photoDetail',
          label: 'Detail photo (upright)',
          help: `A detail — your tools, the tub, the table — upright (4:5). Remove it to show the wide photo alone. ${SAMPLE_HELP}`,
          default: {
            src: '/photos/studio-tools-800.webp',
            alt: 'A clipper, curved scissors and thinning shears with coloured handles lie on a black grooming table among tufts of clipped hair.',
            width: 800,
            height: 1000,
          },
          aspectRatio: 4 / 5,
        },
        {
          type: 'list',
          id: 'studio.facts',
          label: 'How we work',
          itemLabel: 'Fact',
          maxItems: 6,
          fields: [
            { type: 'text', id: 'title', label: 'Fact', default: '', maxLength: 48, required: true },
            { type: 'text', id: 'text', label: 'Detail', default: '', maxLength: 110 },
          ],
          default: [
            { title: 'One dog at a time', text: 'No crate room full of strangers — your dog has the studio to itself.' },
            { title: 'Cleaned between every dog', text: 'Table, tub, tools and towels, every time.' },
            { title: 'Never left alone', text: 'No unattended dryers, no dog alone on a table.' },
            { title: 'Breaks when they need them', text: 'A calm groom matters more than a fast one.' },
          ],
        },
      ],
    },
    {
      id: 'goodToKnow',
      label: 'Good to know',
      description: 'Practical answers before a first appointment. These are sample policies — make them yours.',
      fields: [
        { type: 'text', id: 'faq.title', label: 'Title', help: MARK_HELP, default: 'Good to *know*', maxLength: 48, required: true },
        {
          type: 'list',
          id: 'faq.items',
          label: 'Questions',
          itemLabel: 'Question',
          maxItems: 10,
          fields: [
            { type: 'text', id: 'question', label: 'Question', default: '', maxLength: 120, required: true },
            { type: 'longText', id: 'answer', label: 'Answer', default: '', maxLength: 600, rows: 4 },
          ],
          default: [
            {
              question: 'How should I prepare my dog?',
              answer:
                'A short walk and a toilet stop before you come in, and no big meal just before. If you can brush through the coat in the week before, the groom is quicker and kinder. Bring the lead; we keep everything else.',
            },
            {
              question: 'How long will my dog be with you?',
              answer:
                'The time shown with each service is how long we book your dog in, from drop-off to collection. A small full groom is usually about two hours, a large one about three. We text you when your dog is ready.',
            },
            {
              question: 'My dog’s coat is matted or very thick. What happens?',
              answer:
                'Mention it in the booking notes. Matted or very thick coats take longer and can cost more; we tell you before the appointment. If mats sit close to the skin, the kindest option is often a short clip and a fresh start — we never brush out painful mats for the sake of length.',
            },
            {
              question: 'When can my puppy come for a first groom?',
              answer:
                'From about 12 weeks, once the first vaccinations are done. The Puppy Introduction is short and gentle on purpose: a little bath, a quiet dry, nails and a tidy face, with lots of breaks.',
            },
            {
              question: 'My dog is nervous, older or has special needs.',
              answer:
                'Tell us in the notes — a sentence is enough, no medical records needed — and call us if you would like to talk it through first. We can book a quieter time, keep the visit short, or stop and rebook if your dog has had enough. We are groomers, not vets: for skin problems or anything medical, please see your vet first.',
            },
            {
              question: 'What if I’m running late or need to cancel?',
              answer:
                'Please give us 24 hours’ notice to change or cancel, so another dog can have the time. If you are running more than 15 minutes late, call us — we may need to shorten the groom or move it.',
            },
          ],
        },
      ],
    },
    {
      id: 'book',
      label: 'Booking',
      description: 'The words around the booking. Times and availability come from the engine.',
      fields: [
        { type: 'text', id: 'book.title', label: 'Title', help: MARK_HELP, default: 'Book a *groom*', maxLength: 48, required: true },
        {
          type: 'longText',
          id: 'book.intro',
          label: 'Introduction',
          default: 'Choose a service for one dog and a time to drop off. No account needed — it takes about a minute, and we read your notes about your dog before we confirm.',
          maxLength: 280,
          rows: 2,
        },
      ],
    },
    {
      id: 'visit',
      label: 'Visit',
      description: 'Opening hours, the address, phone and email come from your business settings and opening hours.',
      fields: [
        { type: 'text', id: 'visit.title', label: 'Title', help: MARK_HELP, default: 'Find the *studio*', maxLength: 48, required: true },
        {
          type: 'longText',
          id: 'visit.note',
          label: 'Drop-off & collection',
          default:
            'We are on Upton Avenue, two doors from the corner of 43rd Street — the green door with the bench outside. Free 30-minute parking right in front for drop-off and collection. Please keep your dog on a lead until you are inside.',
          maxLength: 500,
          rows: 4,
        },
      ],
    },
    {
      id: 'footer',
      label: 'Footer',
      fields: [
        {
          type: 'text',
          id: 'footer.tagline',
          label: 'Footer line',
          default: 'Calm, one-dog-at-a-time grooming — Linden Hills, Minneapolis.',
          maxLength: 100,
        },
      ],
    },
  ],
});
