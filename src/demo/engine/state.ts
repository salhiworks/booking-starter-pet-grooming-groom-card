// VENDORED from booking-niche-packs/shared/demo-engine — edit it there, then run scripts/sync-shared.mjs.
import { addDays, todayInTimeZone, weekdayOf } from '@profitstudio/booking-engine';
import type {
  AdminBooking,
  AdminService,
  AdminSettings,
  AvailabilityException,
  EmailStatus,
  OpeningHoursInterval,
  Preset,
} from '@profitstudio/booking-engine';
import { localDate, localTime, zonedTimeToUtc } from './time';

/**
 * THE DEMO'S DATA — one visitor's copy, in their own browser.
 *
 * Everything the dashboard and the website read lives in one JSON document in
 * localStorage under `booking-demo:<id>`. Nothing leaves the browser: no
 * Supabase, no email, no network. Another visitor has their own copy, so
 * nothing one visitor does can reach another. "Reset demo" deletes it and the
 * next read seeds a fresh one.
 */

export interface DemoCustomer {
  name: string;
  email: string;
  phone: string;
}

/** A sample photo attached to a seeded service (bundled with the demo build). */
export interface DemoServicePhoto {
  url: string;
  alt: string;
  width: number;
  height: number;
}

export interface DemoConfig {
  /** Storage namespace, e.g. "hair-salon-atelier". */
  id: string;
  preset: Preset;
  business: {
    name: string;
    timezone: string;
    currency?: string;
    locale?: string;
    email: string;
    phone: string;
    address: string;
  };
  /** Sign-in shown in the demo dashboard (nothing is checked). */
  ownerEmail: string;
  /** Fictional clients for the seeded appointments. */
  customers: DemoCustomer[];
  /** Prefix of booking references, e.g. "CC". */
  referencePrefix: string;
  /** Notes a few sample clients left with their booking (in the niche's own words). */
  sampleNotes?: string[];
  /** Sample photos by service name. */
  servicePhotos?: Record<string, DemoServicePhoto>;
  /** Other localStorage keys the site writes (e.g. its content cache), cleared on reset. */
  resetKeys?: string[];
}

export interface DemoHold {
  serviceId: string;
  startsAt: string;
  endsAt: string;
  customer: { name: string; email: string; phone: string | null };
  notes: string | null;
  expiresAt: number;
  sends: number;
  lastSent: number;
}

export interface DemoState {
  schema: 1;
  /** Business-local date the sample appointments were laid out from. */
  seededOn: string;
  signedIn: boolean;
  services: AdminService[];
  hours: OpeningHoursInterval[];
  exceptions: AvailabilityException[];
  settings: AdminSettings;
  bookings: AdminBooking[];
  holds: Record<string, DemoHold>;
  content: {
    draft: Record<string, unknown>;
    published: Record<string, unknown>;
    draftRevision: number;
    version: number;
    draftUpdatedAt: string | null;
    publishedAt: string | null;
  };
  /** Uploaded images (scaled data URLs) by storage path. */
  images: Record<string, string>;
  emails: EmailStatus['recent'];
}

export const iso = (t: number) => new Date(t).toISOString().replace(/\.\d{3}Z$/, 'Z');

let counter = 0;
export function newId(prefix: string): string {
  counter += 1;
  const random = Math.random().toString(36).slice(2, 10);
  return `${prefix}-${Date.now().toString(36)}${counter}${random}`;
}

const REF_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
export function newReference(prefix: string, taken: Set<string>): string {
  for (;;) {
    let ref = prefix;
    while (ref.length < 8) ref += REF_ALPHABET[Math.floor(Math.random() * REF_ALPHABET.length)];
    if (!taken.has(ref)) return ref;
  }
}

/** A small deterministic generator, so a fresh demo always looks the same. */
function seeded(seed: number) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

/** A fresh demo: the preset's services and hours, the site's business, ~3 weeks of sample appointments. */
export function seedState(config: DemoConfig, now = new Date()): DemoState {
  const tz = config.business.timezone;
  const today = todayInTimeZone(tz, now);
  const created = iso(now.getTime() - 30 * 86_400_000);
  const services: AdminService[] = config.preset.services.map((s, i) => {
    const photo = config.servicePhotos?.[s.name];
    const path = photo ? `services/sample/${i + 1}` : null;
    return {
      id: `svc-${i + 1}`,
      name: s.name,
      description: s.description ?? null,
      durationMinutes: s.durationMinutes,
      bufferAfterMinutes: s.bufferAfterMinutes ?? 0,
      priceCents: s.priceCents ?? null,
      priceFrom: s.priceFrom ?? false,
      isActive: true,
      sortOrder: (i + 1) * 10,
      image: photo && path ? { url: photo.url, path, alt: photo.alt, width: photo.width, height: photo.height } : null,
      createdAt: created,
      updatedAt: created,
    };
  });
  const p = config.preset.policies;
  const settings: AdminSettings = {
    businessName: config.business.name,
    timezone: tz,
    currency: config.business.currency ?? config.preset.previewBusiness.currency,
    locale: config.business.locale ?? config.preset.previewBusiness.locale,
    publicEmail: config.business.email,
    publicPhone: config.business.phone,
    address: config.business.address,
    slotIntervalMinutes: p.slotIntervalMinutes,
    minNoticeMinutes: p.minNoticeMinutes,
    maxAdvanceDays: p.maxAdvanceDays,
    autoConfirm: p.autoConfirm,
    requirePhone: p.requirePhone,
    maxActiveBookingsPerEmail: 3,
    maxWebsiteBookingsPerHour: 30,
    pendingHoldMinutes: p.pendingHoldMinutes,
    ownerNotificationEmail: config.ownerEmail,
    verificationWindowMinutes: p.verificationWindowMinutes,
    maxVerificationEmailsPerDay: 200,
    onlineBookingEnabled: true,
    updatedAt: created,
  };
  const hours = config.preset.workingHours.map((h) => ({ ...h }));
  const bookings = seedBookings(config, services, hours, settings, today, now);
  return {
    schema: 1,
    seededOn: today,
    signedIn: true,
    services,
    hours,
    exceptions: [],
    settings,
    bookings,
    holds: {},
    content: { draft: {}, published: {}, draftRevision: 0, version: 0, draftUpdatedAt: null, publishedAt: null },
    images: {},
    // Nothing is ever emailed from a demo, so it starts with no email history.
    emails: [],
  };
}

/**
 * Sample appointments from 7 days ago to 14 days ahead: completed and the odd
 * no-show in the past, confirmed and a few requests waiting ahead. Each open
 * day keeps most of its times free, so the website always has plenty to book.
 */
function seedBookings(
  config: DemoConfig,
  services: AdminService[],
  hours: OpeningHoursInterval[],
  settings: AdminSettings,
  today: string,
  now: Date,
): AdminBooking[] {
  const tz = settings.timezone;
  const rand = seeded(20261104);
  const out: AdminBooking[] = [];
  const taken = new Set<string>();
  let c = 0;
  for (let offset = -7; offset <= 14; offset++) {
    const date = addDays(today, offset);
    const open = hours.filter((h) => h.weekday === weekdayOf(date));
    if (!open.length) continue;
    const perDay = offset === 0 ? 3 : 1 + Math.floor(rand() * 3);
    let cursor = zonedTimeToUtc(date, open[0].start, tz);
    const close = zonedTimeToUtc(date, open[open.length - 1].end, tz);
    for (let n = 0; n < perDay; n++) {
      const service = services[Math.floor(rand() * services.length)];
      // Leave a gap of 30–120 minutes before each appointment, then land on the
      // booking grid (opening time + whole slot intervals), as a real booking would.
      cursor += (30 + 15 * Math.floor(rand() * 7)) * 60_000;
      const grid = settings.slotIntervalMinutes * 60_000;
      const opening = zonedTimeToUtc(date, open[0].start, tz);
      cursor = opening + Math.ceil((cursor - opening) / grid) * grid;
      const end = cursor + service.durationMinutes * 60_000;
      if (end + service.bufferAfterMinutes * 60_000 > close) break;
      const customer = config.customers[c++ % config.customers.length];
      const past = end < now.getTime();
      const status: AdminBooking['status'] = past
        ? rand() < 0.08
          ? 'no_show'
          : rand() < 0.08
            ? 'cancelled'
            : 'completed'
        : offset <= 4 && rand() < 0.3
          ? 'pending'
          : 'confirmed';
      const createdAt = cursor - (2 + Math.floor(rand() * 9)) * 86_400_000;
      const reference = newReference(config.referencePrefix, taken);
      taken.add(reference);
      out.push({
        id: `bk-seed-${out.length + 1}`,
        reference,
        status,
        holdExpiresAt: status === 'pending' ? iso(Math.min(cursor, now.getTime() + settings.pendingHoldMinutes * 60_000)) : null,
        emailVerified: true,
        startsAt: iso(cursor),
        endsAt: iso(end),
        date,
        time: localTime(cursor, tz),
        endTime: localTime(end, tz),
        serviceId: service.id,
        serviceName: service.name,
        priceCents: service.priceCents,
        currency: settings.currency,
        customer: { ...customer },
        notes: config.sampleNotes?.length && rand() < 0.25 ? config.sampleNotes[Math.floor(rand() * config.sampleNotes.length)] : null,
        source: 'website',
        createdAt: iso(Math.min(createdAt, now.getTime() - 3_600_000)),
        statusChangedAt: iso(Math.min(createdAt + 86_400_000, now.getTime() - 1_800_000)),
      });
      cursor = end + service.bufferAfterMinutes * 60_000;
    }
  }
  return out;
}

// --- Persistence -----------------------------------------------------------------

function storage(): Storage | null {
  try {
    return typeof window !== 'undefined' ? window.localStorage : null;
  } catch {
    return null;
  }
}

export const storageKey = (config: DemoConfig) => `booking-demo:${config.id}`;

/** The visitor's demo, or a fresh one (also when the sample days have gone stale). */
export function loadState(config: DemoConfig, now = new Date()): DemoState {
  try {
    const raw = storage()?.getItem(storageKey(config));
    const parsed = raw ? (JSON.parse(raw) as DemoState) : null;
    if (parsed && parsed.schema === 1) {
      const today = todayInTimeZone(parsed.settings.timezone, now);
      // A demo left for days would show an empty week: start again from today.
      if (addDays(parsed.seededOn, 3) >= today) return parsed;
    }
  } catch {
    /* unreadable: start fresh */
  }
  return seedState(config, now);
}

/** False when the browser refused (storage full or blocked): the change then lives until the page closes. */
export function saveState(config: DemoConfig, state: DemoState): boolean {
  try {
    storage()?.setItem(storageKey(config), JSON.stringify(state));
    return true;
  } catch {
    return false;
  }
}

export function clearState(config: DemoConfig): void {
  const s = storage();
  try {
    s?.removeItem(storageKey(config));
    for (const key of config.resetKeys ?? []) s?.removeItem(key);
  } catch {
    /* nothing to clear */
  }
}

export { localDate };
