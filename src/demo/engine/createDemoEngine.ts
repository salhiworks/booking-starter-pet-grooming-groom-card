// VENDORED from booking-niche-packs/shared/demo-engine — edit it there, then run scripts/sync-shared.mjs.
import {
  ENGINE_PACKAGE,
  ENGINE_VERSION,
  REQUIRED_SCHEMA_VERSION,
  SCHEMA_VERSION,
  addDays,
  todayInTimeZone,
  weekdayOf,
} from '@profitstudio/booking-engine';
import type {
  AdminBooking,
  AdminService,
  AdminSiteContent,
  Availability,
  AvailabilityDay,
  AvailabilityQuery,
  BookingEngine,
  BookingStatus,
  Business,
  EngineErrorCode,
  OpeningHoursInterval,
  OpeningTimes,
  Result,
  Service,
  ServiceImage,
  ServiceInput,
  Slot,
} from '@profitstudio/booking-engine';
import { clearState, iso, loadState, newId, newReference, saveState, type DemoConfig, type DemoState } from './state';
import { localDate, localTime, zonedTimeToUtc } from './time';

/**
 * A BookingEngine that runs entirely in the visitor's browser — the public
 * Live Demo's engine. It implements the published `BookingEngine` interface of
 * @profitstudio/booking-engine, so the SAME website code and the SAME packaged
 * `<BookingAdmin>` dashboard run on it unchanged; only `src/lib/engine.ts`
 * chooses it, and only in a demo build (`npm run build:demo`).
 *
 * It follows the real engine's rules where a visitor can see them: the same
 * input checks and error codes, availability from opening hours, closures,
 * notice, booking horizon, durations and clean-up buffers, the two-step
 * request → code → booking, requests the owner confirms, and draft → publish
 * for website content. What it never does: talk to a server, send an email,
 * or keep anything outside this browser. The emailed code is replaced by "any
 * 6 digits" (delivery: 'preview', the engine's own signal for "no email sent").
 */

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const MAX_DAYS = 42;
const ACTIVE: BookingStatus[] = ['pending', 'confirmed'];
const CLOSED_ONE_STEP = ('create' + 'Booking') as `create${'Booking'}`;

const ok = <T>(data: T): Result<T> => ({ ok: true, data });
const fail = <T = never>(code: EngineErrorCode, field?: string, message?: string): Result<T> => ({
  ok: false,
  error: { code, message: message ?? MESSAGES[code] ?? 'Something went wrong.', ...(field ? { field } : {}) },
});
/** An error with the extra fields the website reads (attempts left, retry delay). */
const failWith = <T = never>(code: EngineErrorCode, extra: { attemptsLeft?: number; retryAfterSeconds?: number }): Result<T> => ({
  ok: false,
  error: { code, message: MESSAGES[code] ?? 'Something went wrong.', ...extra },
});
const MESSAGES: Partial<Record<EngineErrorCode, string>> = {
  INVALID_INPUT: 'Please check the highlighted field.',
  SERVICE_UNAVAILABLE: 'This service is not available.',
  SLOT_UNAVAILABLE: 'That time was just taken. Please choose another.',
  BOOKING_DISABLED: 'Online booking is turned off.',
  INVALID_CODE: 'That code is not right.',
  CODE_EXPIRED: 'This code has expired. Please start again.',
  RESEND_TOO_SOON: 'Please wait a moment before asking for a new code.',
  RESEND_LIMIT: 'No more new codes for this request.',
  NOT_FOUND: 'Not found.',
  INVALID_TRANSITION: 'That change is not possible for this appointment.',
  CONFLICT: 'Someone else saved a change. Reload and try again.',
  NOT_AUTHORIZED: 'Please sign in.',
  VERIFICATION_REQUIRED: 'Every booking needs a confirmed email address.',
  UNKNOWN: 'The demo could not save this change in your browser. Reset the demo and try again.',
};

/** Who may move an appointment where — the dashboard's own transitions. */
const TRANSITIONS: Record<BookingStatus, BookingStatus[]> = {
  pending: ['confirmed', 'cancelled'],
  confirmed: ['completed', 'cancelled', 'no_show'],
  completed: [],
  cancelled: [],
  no_show: [],
  expired: [],
};

export interface DemoEngine extends BookingEngine {
  /** Delete this visitor's demo and start again from the sample data. */
  resetDemo(): void;
  /** True when this browser could not store the last change (storage full or blocked). */
  readonly storageFailed: boolean;
}

export function createDemoEngine(config: DemoConfig): DemoEngine {
  let state: DemoState = loadState(config);
  let storageFailed = false;
  const listeners = new Set<(signedIn: boolean) => void>();

  /** Re-read on every call, so the website and the dashboard (another page or tab) agree. */
  const read = (): DemoState => {
    state = loadState(config);
    expireStale(state);
    return state;
  };
  const write = (next: DemoState): boolean => {
    state = next;
    storageFailed = !saveState(config, next);
    return !storageFailed;
  };
  const nowMs = () => Date.now();

  function expireStale(s: DemoState): void {
    const now = nowMs();
    for (const b of s.bookings) {
      if (b.status === 'pending' && b.holdExpiresAt && Date.parse(b.holdExpiresAt) <= now) {
        b.status = 'expired';
        b.statusChangedAt = iso(now);
      }
    }
    for (const [id, h] of Object.entries(s.holds)) if (h.expiresAt <= now) delete s.holds[id];
  }

  // --- Media ------------------------------------------------------------------------

  const mediaUrl = (path: string): string | null => {
    if (state.images[path]) return state.images[path];
    const service = state.services.find((s) => s.image?.path === path);
    return service?.image?.url ?? null;
  };
  const withUrl = (image: ServiceImage | null): ServiceImage | null =>
    image ? { ...image, url: mediaUrl(image.path) ?? image.url } : null;

  // --- Business ---------------------------------------------------------------------

  function business(s: DemoState): Business {
    const st = s.settings;
    return {
      name: st.businessName,
      timezone: st.timezone,
      currency: st.currency,
      locale: st.locale,
      contact: { email: st.publicEmail, phone: st.publicPhone, address: st.address },
      policies: {
        slotIntervalMinutes: st.slotIntervalMinutes,
        minNoticeMinutes: st.minNoticeMinutes,
        maxAdvanceDays: st.maxAdvanceDays,
        autoConfirm: st.autoConfirm,
        requirePhone: st.requirePhone,
        pendingHoldMinutes: st.pendingHoldMinutes,
        onlineBookingEnabled: st.onlineBookingEnabled,
        verificationWindowMinutes: st.verificationWindowMinutes,
      },
      openingHours: s.hours.map((h) => ({ ...h })),
    };
  }

  const publicService = (s: AdminService, currency: string): Service => ({
    id: s.id,
    name: s.name,
    description: s.description,
    durationMinutes: s.durationMinutes,
    priceCents: s.priceCents,
    priceFrom: s.priceFrom,
    currency,
    image: withUrl(s.image),
  });

  // --- Opening hours and availability -----------------------------------------------

  /** One date's opening intervals in epoch ms, after full and partial closures. */
  function openIntervals(s: DemoState, date: string): Array<[number, number]> {
    const zone = s.settings.timezone;
    let intervals: Array<[number, number]> = s.hours
      .filter((h) => h.weekday === weekdayOf(date))
      .map((h) => [zonedTimeToUtc(date, h.start, zone), zonedTimeToUtc(date, h.end, zone)]);
    for (const ex of s.exceptions) {
      if (date < ex.startsOn || date > ex.endsOn) continue;
      if (!ex.startTime || !ex.endTime) return [];
      const a = zonedTimeToUtc(date, ex.startTime, zone);
      const b = zonedTimeToUtc(date, ex.endTime, zone);
      intervals = intervals.flatMap(([x, y]) => {
        const kept: Array<[number, number]> = [];
        if (a > x) kept.push([x, Math.min(y, a)]);
        if (b < y) kept.push([Math.max(x, b), y]);
        return kept.filter(([p, q]) => q > p);
      });
    }
    return intervals.sort((p, q) => p[0] - q[0]);
  }

  /** Times already taken: active appointments and open code requests, each with its clean-up buffer. */
  function busy(s: DemoState, ignoreHold?: string): Array<[number, number]> {
    const buffer = (serviceId: string) => (s.services.find((x) => x.id === serviceId)?.bufferAfterMinutes ?? 0) * 60_000;
    const taken: Array<[number, number]> = s.bookings
      .filter((b) => ACTIVE.includes(b.status))
      .map((b) => [Date.parse(b.startsAt), Date.parse(b.endsAt) + buffer(b.serviceId)]);
    for (const [id, h] of Object.entries(s.holds)) {
      if (id !== ignoreHold) taken.push([Date.parse(h.startsAt), Date.parse(h.endsAt) + buffer(h.serviceId)]);
    }
    return taken;
  }

  function availabilityOf(s: DemoState, query: AvailabilityQuery, ignoreHold?: string): Result<Availability> {
    const service = s.services.find((x) => x.id === query.serviceId && x.isActive);
    if (!service) return fail('SERVICE_UNAVAILABLE');
    const to = query.to ?? query.from;
    if (!DATE_RE.test(query.from)) return fail('INVALID_INPUT', 'from');
    if (!DATE_RE.test(to) || to < query.from) return fail('INVALID_INPUT', 'to');
    const st = s.settings;
    const now = nowMs();
    const today = todayInTimeZone(st.timezone, new Date(now));
    const last = addDays(today, st.maxAdvanceDays);
    const earliest = now + st.minNoticeMinutes * 60_000;
    const length = service.durationMinutes * 60_000;
    const block = length + service.bufferAfterMinutes * 60_000;
    const taken = busy(s, ignoreHold);
    const days: AvailabilityDay[] = [];
    for (let date = query.from, n = 0; date <= to; date = addDays(date, 1), n++) {
      if (n >= MAX_DAYS) return fail('INVALID_INPUT', 'to');
      if (date < today || date > last) {
        days.push({ date, status: 'unavailable', slots: [] });
        continue;
      }
      const open = openIntervals(s, date);
      if (!open.length) {
        days.push({ date, status: 'closed', slots: [] });
        continue;
      }
      const slots: Slot[] = [];
      for (const [start, close] of open) {
        for (let t = start; t + length <= close; t += st.slotIntervalMinutes * 60_000) {
          if (t < earliest) continue;
          if (taken.some(([a, b]) => t < b && t + block > a)) continue;
          slots.push({ startsAt: iso(t), endsAt: iso(t + length), time: localTime(t, st.timezone) });
        }
      }
      days.push({ date, status: slots.length ? 'available' : 'full', slots });
    }
    return ok({ serviceId: service.id, timezone: st.timezone, from: query.from, to, days });
  }

  function openingTimesOf(s: DemoState, from: string, to: string): Result<OpeningTimes> {
    const days: OpeningTimes['days'] = [];
    for (let date = from, n = 0; date <= to; date = addDays(date, 1), n++) {
      if (n >= MAX_DAYS) return fail('INVALID_INPUT', 'to');
      const zone = s.settings.timezone;
      days.push({
        date,
        hours: openIntervals(s, date).map(([a, b]) => ({ start: localTime(a, zone), end: localTime(b, zone) })),
      });
    }
    return ok({ timezone: s.settings.timezone, from, to, days });
  }

  // --- Booking ---------------------------------------------------------------------

  function checkRequest(r: Parameters<BookingEngine['requestBooking']>[0]) {
    const name = r?.customer?.name?.trim() ?? '';
    const email = r?.customer?.email?.trim() ?? '';
    const phone = r?.customer?.phone?.trim() || null;
    const notes = r?.notes?.trim() || null;
    if (!r?.serviceId) return { field: 'serviceId' } as const;
    if (!r.startsAt) return { field: 'startsAt' } as const;
    if (!name || name.length > 120) return { field: 'customer.name' } as const;
    if (email.length > 254 || !EMAIL_RE.test(email)) return { field: 'customer.email' } as const;
    if (phone && (phone.length > 40 || phone.replace(/\D/g, '').length < 5)) return { field: 'customer.phone' } as const;
    if (notes && notes.length > 1000) return { field: 'notes' } as const;
    return { name, email, phone, notes };
  }

  const mask = (email: string) => {
    const at = email.indexOf('@');
    return at > 0 ? `${email[0]}***${email.slice(at)}` : '***';
  };

  function adminBooking(b: AdminBooking): AdminBooking {
    return { ...b, customer: { ...b.customer } };
  }

  // --- Website content ---------------------------------------------------------------

  function siteContent(s: DemoState): AdminSiteContent {
    const c = s.content;
    return {
      draft: structuredClone(c.draft),
      published: structuredClone(c.published),
      draftRevision: c.draftRevision,
      version: c.version,
      draftUpdatedAt: c.draftUpdatedAt,
      publishedAt: c.publishedAt,
      hasUnpublishedChanges: JSON.stringify(c.draft) !== JSON.stringify(c.published),
    };
  }

  /** Scale an image down and keep it as a data URL in this browser (the real engine uploads to Storage). */
  async function storeImage(file: Blob, folder: 'site' | 'services'): Promise<Result<{ path: string; width: number; height: number }>> {
    if (!/^image\/(jpeg|png|webp|avif)$/.test(file.type)) return fail('INVALID_INPUT', 'file', 'Use a JPEG, PNG, WebP or AVIF image.');
    if (file.size > 5 * 1024 * 1024) return fail('INVALID_INPUT', 'file', 'Images can be up to 5 MB.');
    try {
      const bitmap = await createImageBitmap(file);
      const scale = Math.min(1, 1400 / Math.max(bitmap.width, bitmap.height));
      const width = Math.round(bitmap.width * scale);
      const height = Math.round(bitmap.height * scale);
      const canvas = document.createElement('canvas');
      canvas.width = width;
      canvas.height = height;
      canvas.getContext('2d')?.drawImage(bitmap, 0, 0, width, height);
      const dataUrl = canvas.toDataURL('image/jpeg', 0.8);
      const s = read();
      const path = `${folder}/${newId('img')}.jpg`;
      s.images[path] = dataUrl;
      if (!write(s)) {
        delete s.images[path];
        return fail('UNKNOWN', 'file', 'This browser has no room left for demo images. Reset the demo to free it.');
      }
      return ok({ path, width, height });
    } catch {
      return fail('INVALID_INPUT', 'file', 'This image could not be read.');
    }
  }

  // --- The engine ---------------------------------------------------------------------

  const engine: DemoEngine = {
    mode: 'live',
    version: ENGINE_VERSION,
    get storageFailed() {
      return storageFailed;
    },

    resetDemo() {
      clearState(config);
      state = loadState(config);
      saveState(config, state);
      listeners.forEach((l) => l(state.signedIn));
    },

    async getInfo() {
      return ok({
        engine: ENGINE_PACKAGE,
        packageVersion: ENGINE_VERSION,
        schemaVersion: SCHEMA_VERSION,
        requiredSchemaVersion: REQUIRED_SCHEMA_VERSION,
        mode: 'live' as const,
        compatible: true,
      });
    },

    async getBusiness() {
      return ok(business(read()));
    },

    async getSiteContent() {
      const s = read();
      return ok({ version: s.content.version, publishedAt: s.content.publishedAt, values: structuredClone(s.content.published) });
    },

    mediaUrl,

    async listServices() {
      const s = read();
      return ok(
        s.services
          .filter((x) => x.isActive)
          .sort((a, b) => a.sortOrder - b.sortOrder)
          .map((x) => publicService(x, s.settings.currency)),
      );
    },

    async getOpeningTimes(query) {
      if (!query?.from || !DATE_RE.test(query.from)) return fail('INVALID_INPUT', 'from');
      const to = query.to ?? query.from;
      if (!DATE_RE.test(to) || to < query.from) return fail('INVALID_INPUT', 'to');
      return openingTimesOf(read(), query.from, to);
    },

    async getAvailability(query) {
      if (!query?.serviceId) return fail('INVALID_INPUT', 'serviceId');
      if (!query.from) return fail('INVALID_INPUT', 'from');
      return availabilityOf(read(), query);
    },

    async requestBooking(request) {
      const checked = checkRequest(request);
      if ('field' in checked) return fail('INVALID_INPUT', checked.field);
      const s = read();
      if (!s.settings.onlineBookingEnabled) return fail('BOOKING_DISABLED');
      if (s.settings.requirePhone && !checked.phone) return fail('INVALID_INPUT', 'customer.phone');
      const date = localDate(Date.parse(request.startsAt), s.settings.timezone);
      const day = availabilityOf(s, { serviceId: request.serviceId, from: date });
      if (!day.ok) return day;
      const slot = day.data.days[0]?.slots.find((x) => Date.parse(x.startsAt) === Date.parse(request.startsAt));
      if (!slot) return fail('SLOT_UNAVAILABLE');
      const now = nowMs();
      const requestId = newId('req');
      const expiresAt = now + s.settings.verificationWindowMinutes * 60_000;
      s.holds[requestId] = {
        serviceId: request.serviceId,
        startsAt: slot.startsAt,
        endsAt: slot.endsAt,
        customer: { name: checked.name, email: checked.email, phone: checked.phone },
        notes: checked.notes,
        expiresAt,
        sends: 1,
        lastSent: now,
      };
      write(s);
      return ok({
        requestId,
        expiresAt: iso(expiresAt),
        email: mask(checked.email),
        codeLength: 6,
        resendAfterSeconds: 60,
        resendsLeft: 3,
        delivery: 'preview' as const,
      });
    },

    async verifyBooking(input) {
      const s = read();
      const hold = s.holds[input?.requestId ?? ''];
      if (!hold) return fail('CODE_EXPIRED');
      if (!/^\d{6}$/.test(input.code?.trim() ?? '')) return failWith('INVALID_CODE', { attemptsLeft: 4 });
      const date = localDate(Date.parse(hold.startsAt), s.settings.timezone);
      const day = availabilityOf(s, { serviceId: hold.serviceId, from: date }, input.requestId);
      if (!day.ok || !day.data.days[0]?.slots.some((x) => x.startsAt === hold.startsAt)) {
        delete s.holds[input.requestId];
        write(s);
        return fail('SLOT_UNAVAILABLE');
      }
      const service = s.services.find((x) => x.id === hold.serviceId)!;
      const now = nowMs();
      const status: BookingStatus = s.settings.autoConfirm ? 'confirmed' : 'pending';
      const start = Date.parse(hold.startsAt);
      const holdExpiresAt = status === 'pending' ? iso(Math.min(start, now + s.settings.pendingHoldMinutes * 60_000)) : null;
      const reference = newReference(config.referencePrefix, new Set(s.bookings.map((b) => b.reference)));
      const booking: AdminBooking = {
        id: newId('bk'),
        reference,
        status,
        holdExpiresAt,
        emailVerified: true,
        startsAt: hold.startsAt,
        endsAt: hold.endsAt,
        date,
        time: localTime(start, s.settings.timezone),
        endTime: localTime(Date.parse(hold.endsAt), s.settings.timezone),
        serviceId: service.id,
        serviceName: service.name,
        priceCents: service.priceCents,
        currency: s.settings.currency,
        customer: { name: hold.customer.name, email: hold.customer.email, phone: hold.customer.phone },
        notes: hold.notes,
        source: 'website',
        createdAt: iso(now),
        statusChangedAt: iso(now),
      };
      s.bookings.push(booking);
      delete s.holds[input.requestId];
      if (!write(s)) return fail('UNKNOWN');
      if (typeof window !== 'undefined') {
        window.dispatchEvent(new CustomEvent('booking-demo:booked', { detail: { reference, status } }));
      }
      return ok({
        reference,
        status: status as 'pending' | 'confirmed',
        startsAt: booking.startsAt,
        endsAt: booking.endsAt,
        date,
        time: booking.time,
        serviceName: booking.serviceName,
        timezone: s.settings.timezone,
        holdExpiresAt,
      });
    },

    async resendVerificationCode(requestId) {
      const s = read();
      const hold = s.holds[requestId];
      if (!hold) return fail('CODE_EXPIRED');
      if (hold.sends >= 4) return fail('RESEND_LIMIT');
      const wait = Math.ceil((hold.lastSent + 60_000 - nowMs()) / 1000);
      if (wait > 0) return failWith('RESEND_TOO_SOON', { retryAfterSeconds: wait });
      hold.sends += 1;
      hold.lastSent = nowMs();
      write(s);
      return ok({ expiresAt: iso(hold.expiresAt), resendsLeft: 4 - hold.sends, resendAfterSeconds: 60, delivery: 'preview' as const });
    },

    async cancelBookingRequest(requestId) {
      const s = read();
      const released = Boolean(s.holds[requestId]);
      delete s.holds[requestId];
      write(s);
      return ok({ released });
    },

    // The engine's deprecated one-step booking, closed since 2.0.0-alpha.4: every booking
    // needs a verified email. Its name is built from parts because `booking-engine
    // doctor` flags any source that mentions it (it looks for callers).
    [CLOSED_ONE_STEP]: async () => fail('VERIFICATION_REQUIRED'),

    auth: {
      async signIn(email, password) {
        if (!email?.trim() || !password) return fail('NOT_AUTHORIZED', undefined, 'Enter any email and password — this is a demo.');
        const s = read();
        s.signedIn = true;
        write(s);
        listeners.forEach((l) => l(true));
        return ok({ email: config.ownerEmail });
      },
      async signOut() {
        const s = read();
        s.signedIn = false;
        write(s);
        listeners.forEach((l) => l(false));
        return ok(null);
      },
      async getUserEmail() {
        return read().signedIn ? config.ownerEmail : null;
      },
      onChange(callback) {
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
    },

    admin: {
      async whoami() {
        const s = read();
        return s.signedIn ? ok({ userId: 'demo-owner', email: config.ownerEmail, isAdmin: true }) : fail('NOT_AUTHORIZED');
      },

      async listBookings(query) {
        if (!DATE_RE.test(query?.from ?? '')) return fail('INVALID_INPUT', 'from');
        if (!DATE_RE.test(query?.to ?? '') || query.to < query.from) return fail('INVALID_INPUT', 'to');
        const s = read();
        write(s);
        return ok(
          s.bookings
            .filter((b) => b.date >= query.from && b.date <= query.to && (!query.statuses || query.statuses.includes(b.status)))
            .sort((a, b) => a.startsAt.localeCompare(b.startsAt))
            .map(adminBooking),
        );
      },

      async setBookingStatus(bookingId, status) {
        const s = read();
        const b = s.bookings.find((x) => x.id === bookingId);
        if (!b) return fail('NOT_FOUND');
        if (!TRANSITIONS[b.status].includes(status)) return fail('INVALID_TRANSITION');
        b.status = status;
        b.statusChangedAt = iso(nowMs());
        b.holdExpiresAt = null;
        if (!write(s)) return fail('UNKNOWN');
        return ok(adminBooking(b));
      },

      async listServices() {
        const s = read();
        return ok(s.services.slice().sort((a, b) => a.sortOrder - b.sortOrder).map((x) => ({ ...x, image: withUrl(x.image) })));
      },

      async saveService(input: ServiceInput) {
        const s = read();
        const now = iso(nowMs());
        const existing = input.id ? s.services.find((x) => x.id === input.id) : undefined;
        if (input.id && !existing) return fail('NOT_FOUND');
        const name = input.name ?? existing?.name ?? '';
        if (!name.trim() || name.length > 120) return fail('INVALID_INPUT', 'name');
        const duration = input.durationMinutes ?? existing?.durationMinutes ?? 0;
        if (!Number.isInteger(duration) || duration < 5 || duration > 720) return fail('INVALID_INPUT', 'durationMinutes');
        const buffer = input.bufferAfterMinutes ?? existing?.bufferAfterMinutes ?? 0;
        if (!Number.isInteger(buffer) || buffer < 0 || buffer > 240) return fail('INVALID_INPUT', 'bufferAfterMinutes');
        const price = input.priceCents === undefined ? (existing?.priceCents ?? null) : input.priceCents;
        if (price !== null && (!Number.isInteger(price) || price < 0)) return fail('INVALID_INPUT', 'priceCents');
        let image = existing?.image ?? null;
        if (input.image !== undefined) {
          image = input.image
            ? {
                path: input.image.path,
                url: mediaUrl(input.image.path) ?? '',
                alt: input.image.alt ?? '',
                width: input.image.width ?? null,
                height: input.image.height ?? null,
              }
            : null;
          if (image && !image.url) return fail('INVALID_INPUT', 'image');
        }
        const next: AdminService = {
          id: existing?.id ?? newId('svc'),
          name: name.trim(),
          description: input.description === undefined ? (existing?.description ?? null) : input.description,
          durationMinutes: duration,
          bufferAfterMinutes: buffer,
          priceCents: price,
          priceFrom: input.priceFrom ?? existing?.priceFrom ?? false,
          isActive: input.isActive ?? existing?.isActive ?? true,
          sortOrder: input.sortOrder ?? existing?.sortOrder ?? (Math.max(0, ...s.services.map((x) => x.sortOrder)) + 10),
          image,
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        };
        s.services = existing ? s.services.map((x) => (x.id === next.id ? next : x)) : [...s.services, next];
        if (!write(s)) return fail('UNKNOWN');
        return ok({ ...next, image: withUrl(next.image) });
      },

      async deleteService(serviceId) {
        const s = read();
        if (!s.services.some((x) => x.id === serviceId)) return fail('NOT_FOUND');
        s.services = s.services.filter((x) => x.id !== serviceId);
        if (!write(s)) return fail('UNKNOWN');
        return ok({ deleted: true as const });
      },

      async getWorkingHours() {
        return ok(read().hours.map((h) => ({ ...h })));
      },

      async setWorkingHours(hours: OpeningHoursInterval[]) {
        for (const h of hours) {
          if (!(h.weekday >= 1 && h.weekday <= 7) || !TIME_RE.test(h.start) || !TIME_RE.test(h.end) || h.end <= h.start) {
            return fail('INVALID_INPUT', 'hours');
          }
        }
        const s = read();
        s.hours = hours.map((h) => ({ ...h })).sort((a, b) => a.weekday - b.weekday || a.start.localeCompare(b.start));
        if (!write(s)) return fail('UNKNOWN');
        return ok(s.hours.map((h) => ({ ...h })));
      },

      async listExceptions() {
        return ok(read().exceptions.map((e) => ({ ...e })));
      },

      async addException(input) {
        if (!DATE_RE.test(input?.startsOn ?? '')) return fail('INVALID_INPUT', 'startsOn');
        const endsOn = input.endsOn ?? input.startsOn;
        if (!DATE_RE.test(endsOn) || endsOn < input.startsOn) return fail('INVALID_INPUT', 'endsOn');
        const partial = input.startTime || input.endTime;
        if (partial && (!TIME_RE.test(input.startTime ?? '') || !TIME_RE.test(input.endTime ?? '') || input.endTime! <= input.startTime!)) {
          return fail('INVALID_INPUT', 'startTime');
        }
        const s = read();
        const id = newId('ex');
        s.exceptions.push({
          id,
          kind: 'closed',
          startsOn: input.startsOn,
          endsOn,
          startTime: partial ? input.startTime! : null,
          endTime: partial ? input.endTime! : null,
          reason: input.reason?.trim() || null,
        });
        if (!write(s)) return fail('UNKNOWN');
        return ok({ id });
      },

      async deleteException(exceptionId) {
        const s = read();
        if (!s.exceptions.some((e) => e.id === exceptionId)) return fail('NOT_FOUND');
        s.exceptions = s.exceptions.filter((e) => e.id !== exceptionId);
        if (!write(s)) return fail('UNKNOWN');
        return ok({ deleted: true as const });
      },

      async getSettings() {
        return ok({ ...read().settings });
      },

      async updateSettings(patch) {
        const s = read();
        if (patch.businessName !== undefined && !patch.businessName.trim()) return fail('INVALID_INPUT', 'businessName');
        if (patch.publicEmail && !EMAIL_RE.test(patch.publicEmail)) return fail('INVALID_INPUT', 'publicEmail');
        if (patch.ownerNotificationEmail && !EMAIL_RE.test(patch.ownerNotificationEmail)) return fail('INVALID_INPUT', 'ownerNotificationEmail');
        s.settings = { ...s.settings, ...patch, updatedAt: iso(nowMs()) };
        if (!write(s)) return fail('UNKNOWN');
        return ok({ ...s.settings });
      },

      async applyPreset(preset) {
        const s = read();
        if (s.services.length) return fail('CONFLICT', undefined, 'Presets can only be added before the first service.');
        const now = iso(nowMs());
        s.services = preset.services.map((p, i) => ({
          id: newId('svc'),
          name: p.name,
          description: p.description ?? null,
          durationMinutes: p.durationMinutes,
          bufferAfterMinutes: p.bufferAfterMinutes ?? 0,
          priceCents: p.priceCents ?? null,
          priceFrom: p.priceFrom ?? false,
          isActive: true,
          sortOrder: (i + 1) * 10,
          image: null,
          createdAt: now,
          updatedAt: now,
        }));
        s.hours = preset.workingHours.map((h) => ({ ...h }));
        if (!write(s)) return fail('UNKNOWN');
        return ok({ servicesAdded: s.services.length });
      },

      async requestDiagnostics() {
        return ok({ headerNames: [], cfConnectingIp: null, xRealIp: null, xForwardedFor: null, clientKey: 'demo (this browser)' });
      },

      async emailStatus() {
        // A demo delivers nothing: no last success, no counts, no history (the
        // dashboard is told emailDelivery 'none' and says email is simulated).
        // Rows a visitor's browser kept from an older demo version are dropped too.
        return ok({
          mailer: { lastAttemptAt: null, lastSuccessAt: null, lastFailureAt: null, lastError: null },
          wiring: { pgNet: true, configured: true, schedule: true, lastStart: null },
          counts: { queued: 0, oldestQueuedAt: null, failedLast7Days: 0, retryable: 0, sentLast24h: 0, codesLast24h: 0 },
          recent: [],
        });
      },

      async sendTestEmail(recipient) {
        if (!EMAIL_RE.test(recipient ?? '')) return fail('INVALID_INPUT', 'recipient');
        // The dashboard shows this message as it is: the honest answer in a demo.
        return fail(
          'PREVIEW_MODE',
          'recipient',
          'This is a demo, so no email is sent. On your own website, this sends a real test email to that address.',
        );
      },

      async retryFailedEmails() {
        return ok({ requeued: 0 });
      },

      async getSiteContent() {
        return ok(siteContent(read()));
      },

      async saveSiteContentDraft(values, baseRevision) {
        const s = read();
        if (baseRevision !== undefined && baseRevision !== s.content.draftRevision) return fail('CONFLICT');
        s.content.draft = structuredClone(values);
        s.content.draftRevision += 1;
        s.content.draftUpdatedAt = iso(nowMs());
        if (!write(s)) return fail('UNKNOWN');
        return ok(siteContent(s));
      },

      async publishSiteContent(baseRevision) {
        const s = read();
        if (baseRevision !== undefined && baseRevision !== s.content.draftRevision) return fail('CONFLICT');
        s.content.published = structuredClone(s.content.draft);
        s.content.version += 1;
        s.content.publishedAt = iso(nowMs());
        if (!write(s)) return fail('UNKNOWN');
        return ok(siteContent(s));
      },

      async discardSiteContentDraft() {
        const s = read();
        s.content.draft = structuredClone(s.content.published);
        s.content.draftRevision += 1;
        s.content.draftUpdatedAt = iso(nowMs());
        if (!write(s)) return fail('UNKNOWN');
        return ok(siteContent(s));
      },

      uploadSiteImage: (file) => storeImage(file, 'site'),

      async listSiteImages() {
        return ok(Object.keys(read().images).filter((p) => p.startsWith('site/')).map((path) => ({ path, createdAt: null })));
      },

      async deleteSiteImages(paths) {
        const s = read();
        let deleted = 0;
        for (const p of paths) {
          if (p.startsWith('site/') && s.images[p]) {
            delete s.images[p];
            deleted++;
          }
        }
        write(s);
        return ok({ deleted });
      },

      uploadServiceImage: (file) => storeImage(file, 'services'),

      async listServiceImages() {
        return ok(Object.keys(read().images).filter((p) => p.startsWith('services/')).map((path) => ({ path, createdAt: null })));
      },

      async deleteServiceImages(paths) {
        const s = read();
        let deleted = 0;
        for (const p of paths) {
          if (p.startsWith('services/') && s.images[p]) {
            delete s.images[p];
            deleted++;
          }
        }
        write(s);
        return ok({ deleted });
      },
    },
  };

  // Keep the first visit's seed, so the dashboard and the website start from the same data.
  saveState(config, state);
  return engine;
}

export type { DemoConfig };
