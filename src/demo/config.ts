import type { DemoConfig } from './engine';
import { sitePreset } from '../lib/preset';

/**
 * The public Live Demo's sample studio (`npm run dev:demo` / `npm run build:demo`).
 * Only demo builds read this file. Customizing the real website? Leave src/demo/ alone.
 */
export const demoConfig: DemoConfig = {
  id: 'pet-grooming-groom-card',
  preset: sitePreset,
  business: {
    name: 'Brindle Grooming Studio',
    timezone: 'America/Chicago',
    email: 'hello@brindle.example',
    phone: '+1 612-555-0147',
    address: '4312 Upton Avenue S, Minneapolis, MN 55410',
  },
  ownerEmail: 'owner@brindle.example',
  referencePrefix: 'BG',
  sampleNotes: [
    'Biscuit, cockapoo, about 22 lb. Teddy face, an inch all over please. A little nervous of the dryer.',
    'Juno, Bernese, 95 lb — heavy shedding season. Happy to drop her off early.',
    'Pip, 4-month Maltese puppy, first groom. Fully vaccinated.',
  ],
  // The site caches published content under this key (createSiteContentStore's default).
  resetKeys: ['pbe-site-content'],
  customers: [
    { name: 'Hannah Lindqvist', email: 'hannah.l@example.com', phone: '+1 612 555 0113' },
    { name: 'Marcus Webb', email: 'marcus.webb@example.com', phone: '+1 612 555 0126' },
    { name: 'Priya Raman', email: 'priya.raman@example.com', phone: '+1 612 555 0131' },
    { name: 'Daniel Okafor', email: 'd.okafor@example.com', phone: '+1 612 555 0148' },
    { name: 'Ruth Castellano', email: 'ruth.c@example.com', phone: '+1 612 555 0152' },
    { name: 'Kenji Mori', email: 'kenji.mori@example.com', phone: '+1 612 555 0167' },
    { name: 'Alice Moreau', email: 'alice.moreau@example.com', phone: '+1 612 555 0174' },
    { name: 'Tom Haverford', email: 'tom.h@example.com', phone: '+1 612 555 0189' },
    { name: 'Grace Achebe', email: 'grace.a@example.com', phone: '+1 612 555 0193' },
    { name: 'Leo Brandt', email: 'leo.brandt@example.com', phone: '+1 612 555 0108' },
  ],
};
