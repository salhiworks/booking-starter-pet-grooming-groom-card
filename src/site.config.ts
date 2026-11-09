/**
 * This website's identity — the ONE place for its name, time zone and the
 * placeholder contact details shown in preview mode (`npm run dev` without
 * Supabase). Everything the owner manages (services, prices, hours, real
 * contact details, text and photos) lives in the dashboard at /admin/.
 */
export const SITE = {
  /** The business name. The dashboard's Business page overrides it once connected. */
  name: 'Brindle Grooming Studio',
  /** IANA time zone of the business. */
  timezone: 'America/Chicago',
  /** Fictional contact details for preview mode only. */
  previewContact: {
    email: 'hello@brindle.example',
    phone: '+1 612-555-0147',
    address: '4312 Upton Avenue S, Minneapolis, MN 55410',
  },
};
