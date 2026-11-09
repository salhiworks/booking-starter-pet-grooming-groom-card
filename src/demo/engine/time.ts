// VENDORED from booking-niche-packs/shared/demo-engine — edit it there, then run scripts/sync-shared.mjs.
/**
 * Business-time-zone arithmetic for the demo engine, the same rules the real
 * engine uses (its zonedTimeToUtc is internal, so it is mirrored here).
 */

function offsetMinutes(utcMs: number, timezone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: timezone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(new Date(utcMs));
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? 0);
  const asUtc = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'));
  return Math.round((asUtc - Math.floor(utcMs / 1000) * 1000) / 60_000);
}

/** "YYYY-MM-DD" + "HH:MM" in `timezone` → epoch milliseconds. */
export function zonedTimeToUtc(date: string, time: string, timezone: string): number {
  const [y, m, d] = date.split('-').map(Number);
  const [hh, mm] = time.split(':').map(Number);
  const naive = Date.UTC(y, m - 1, d, hh ?? 0, mm ?? 0);
  let guess = naive - offsetMinutes(naive, timezone) * 60_000;
  guess = naive - offsetMinutes(guess, timezone) * 60_000;
  return guess;
}

function parts(utcMs: number, timezone: string) {
  const p = new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).formatToParts(new Date(utcMs));
  const get = (type: string) => p.find((x) => x.type === type)?.value ?? '00';
  return { date: `${get('year')}-${get('month')}-${get('day')}`, time: `${get('hour')}:${get('minute')}` };
}

/** The business-local calendar date of an instant. */
export const localDate = (utcMs: number, timezone: string) => parts(utcMs, timezone).date;
/** The business-local "HH:MM" of an instant. */
export const localTime = (utcMs: number, timezone: string) => parts(utcMs, timezone).time;
