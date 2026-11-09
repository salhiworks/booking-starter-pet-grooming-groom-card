import { createBookingEngine, type BookingEngine } from '@profitstudio/booking-engine';
import { createDemoEngine } from '../demo/engine';
import { demoConfig } from '../demo/config';
import { SITE } from '../site.config';
import { sitePreset } from './preset';

/**
 * The ONE engine instance for the public site and the dashboard.
 * Without VITE_SUPABASE_URL + VITE_SUPABASE_PUBLISHABLE_KEY it runs in preview
 * (development only) with this site's sample data, or reports "unconfigured"
 * in a production build.
 */
const realEngine = (): BookingEngine => createBookingEngine({
  supabaseUrl: import.meta.env.VITE_SUPABASE_URL,
  supabaseKey: import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
  // Preview: fictional data while no backend is connected. Development only.
  allowPreview: import.meta.env.DEV,
  preview: {
    preset: sitePreset,
    // src/site.config.ts — placeholders until the owner's real details come from the dashboard.
    business: { name: SITE.name, timezone: SITE.timezone, contact: SITE.previewContact },
  },
});

/**
 * The public Live Demo (`npm run build:demo`) swaps in an in-browser engine with
 * sample data — no Supabase, no email. `__BOOKING_DEMO__` is a build-time
 * constant (vite.config.ts), so a normal build contains none of the demo code.
 */
export const engine: BookingEngine = __BOOKING_DEMO__ ? createDemoEngine(demoConfig) : realEngine();
