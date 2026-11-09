import type { Preset } from '@profitstudio/booking-engine';

/**
 * Brindle Grooming Studio's own preset (INTEGRATION.md §5): the sample
 * services, hours and policies preview mode shows, and the starter set the
 * dashboard offers an owner who has no services yet (<BookingAdmin presets>).
 * Prices are in US dollars, in cents.
 *
 * One groomer, one table, one dog at a time: the engine keeps ONE shared
 * calendar, so a service's length is the time the dog is in the studio (drop-off
 * to collection), and the buffer after it is the table's reset (clean-down,
 * tools, the groom card). One booking is one dog and one service.
 *
 * The engine has no size, breed or weight pricing: each size of a full groom
 * or bath is its own service, with the size in its NAME ("Full Groom — Small
 * Dog"), and the website reads the size from there (src/lib/services.ts).
 * Prices that can rise with coat condition are starting prices (`priceFrom`);
 * the studio confirms every request (`autoConfirm: false`) and says before the
 * appointment if a coat needs more time.
 *
 * Who a service is for is written at the end of its description after "For:",
 * separated by "·" — the website shows it as a short line.
 */
export const sitePreset = {
  id: 'pet-grooming',
  label: 'Pet Grooming Studio',
  terminology: { customer: 'client', customers: 'clients', booking: 'appointment', bookings: 'appointments' },
  previewBusiness: {
    name: 'Sample Grooming Studio',
    currency: 'USD',
    locale: 'en-US',
    contact: {
      email: 'hello@example.com',
      phone: '+1 612-555-0100',
      address: '100 Example Street, Minneapolis, MN',
    },
  },
  policies: {
    slotIntervalMinutes: 15,
    minNoticeMinutes: 1440,
    maxAdvanceDays: 60,
    autoConfirm: false,
    requirePhone: true,
    pendingHoldMinutes: 1440,
    verificationWindowMinutes: 15,
  },
  // Drop-offs from 8:00 Tuesday to Saturday; a shorter Saturday; closed Sunday and Monday.
  workingHours: [
    { weekday: 2, start: '08:00', end: '17:00' },
    { weekday: 3, start: '08:00', end: '17:00' },
    { weekday: 4, start: '08:00', end: '18:00' },
    { weekday: 5, start: '08:00', end: '17:00' },
    { weekday: 6, start: '08:00', end: '14:00' },
  ],
  services: [
    {
      name: 'Full Groom — Small Dog',
      description:
        'Bath, blow-dry and brush-out, then a full haircut by clipper and scissors, nails, ears and a tidy face and feet. Dogs up to about 20 lb. Matted or neglected coats can take longer and cost more — we confirm before the day. For: Shih Tzus, Yorkies, Maltese, Bichons, mini Poodles',
      durationMinutes: 120,
      bufferAfterMinutes: 15,
      priceCents: 8500,
      priceFrom: true,
    },
    {
      name: 'Full Groom — Medium Dog',
      description:
        'Everything in a full groom for dogs of about 21–50 lb, with more time for the dry and the scissor work. Coat condition can change the time and price — we confirm before the day. For: Cockapoos, Schnauzers, Cocker Spaniels, Westies, smaller doodles',
      durationMinutes: 150,
      bufferAfterMinutes: 15,
      priceCents: 11000,
      priceFrom: true,
    },
    {
      name: 'Full Groom — Large Dog',
      description:
        'A full groom for dogs of about 51–90 lb: a long bath and a thorough dry, then the full haircut. Heavy, curly or matted coats can take longer — we confirm before the day. For: Standard Poodles, Goldendoodles, Old English Sheepdogs, large Spaniels',
      durationMinutes: 180,
      bufferAfterMinutes: 15,
      priceCents: 14500,
      priceFrom: true,
    },
    {
      name: 'Bath & Brush — Small & Medium Dog',
      description:
        'A warm bath with a shampoo chosen for the coat, a careful blow-dry and a full brush-out, nails and ears. No haircut. Dogs up to about 50 lb. For: short and smooth coats · a fresh coat between full grooms',
      durationMinutes: 75,
      bufferAfterMinutes: 15,
      priceCents: 6000,
      priceFrom: true,
    },
    {
      name: 'Bath & Brush — Large Dog',
      description:
        'The same bath, dry and brush-out for dogs of about 51–90 lb, with time for a thick coat to dry properly. No haircut. For: Labradors, Retrievers, Boxers · a fresh coat between full grooms',
      durationMinutes: 105,
      bufferAfterMinutes: 15,
      priceCents: 8500,
      priceFrom: true,
    },
    {
      name: 'Deshedding Bath & Blow-out',
      description:
        'A bath with a deshedding conditioner, then a high-velocity dry and a long brush-out to lift the loose undercoat. Never a shave-down of a double coat. Price for medium dogs; larger and heavier coats cost more — we confirm before the day. For: Huskies, Shepherds, Corgis, Retrievers, Bernese',
      durationMinutes: 120,
      bufferAfterMinutes: 15,
      priceCents: 9500,
      priceFrom: true,
    },
    {
      name: 'Puppy Introduction',
      description:
        'A short, gentle first visit: a little bath, a dry at low speed, a brush, nails and a tidy face — at the puppy’s pace, with plenty of breaks. For: puppies from 12 weeks to 6 months · after their vaccinations',
      durationMinutes: 45,
      bufferAfterMinutes: 15,
      priceCents: 4500,
      priceFrom: false,
    },
    {
      name: 'Face, Feet & Hygiene Tidy',
      description:
        'A tidy between full grooms: around the eyes and muzzle, the paw pads and feet, and the sanitary area, plus nails. No bath. For: dogs of any size · four to six weeks after a full groom',
      durationMinutes: 45,
      bufferAfterMinutes: 15,
      priceCents: 4000,
      priceFrom: false,
    },
    {
      name: 'Nail Trim',
      description:
        'Nails clipped and the edges smoothed, with a look at the paw pads. A walk-in-and-out visit. For: dogs of any size · every four to six weeks',
      durationMinutes: 15,
      bufferAfterMinutes: 15,
      priceCents: 2000,
      priceFrom: false,
    },
  ],
} satisfies Preset;
