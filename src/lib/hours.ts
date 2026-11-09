import { addDays, formatClockTime, formatDate } from '@profitstudio/booking-engine';
import type { OpeningHoursInterval, OpeningTimesDay } from '@profitstudio/booking-engine';

type Range = { start: string; end: string };

const WEEKDAYS = [1, 2, 3, 4, 5, 6, 7] as const;

/** "Monday" … "Sunday" in the business locale (2024-01-01 was a Monday). */
export function weekdayName(weekday: number, locale: string, style: 'long' | 'short' = 'long'): string {
  return new Intl.DateTimeFormat(locale, { weekday: style, timeZone: 'UTC' }).format(Date.UTC(2024, 0, weekday));
}

export function rangeLabel(range: Range, locale: string): string {
  return `${formatClockTime(range.start, locale)} – ${formatClockTime(range.end, locale)}`;
}

function rangesFor(weekday: number, hours: readonly OpeningHoursInterval[]): Range[] {
  return hours
    .filter((h) => h.weekday === weekday)
    .map(({ start, end }) => ({ start, end }))
    .sort((a, b) => a.start.localeCompare(b.start));
}

const sameRanges = (a: Range[], b: Range[]) =>
  a.length === b.length && a.every((r, i) => r.start === b[i].start && r.end === b[i].end);

export interface HoursRow {
  weekdays: number[];
  label: string;
  hours: string;
}

/** The weekly pattern as calm rows: consecutive days with the same hours share a row. */
export function weeklyRows(hours: readonly OpeningHoursInterval[], locale: string): HoursRow[] {
  const rows: Array<{ weekdays: number[]; ranges: Range[] }> = [];
  for (const weekday of WEEKDAYS) {
    const ranges = rangesFor(weekday, hours);
    const last = rows[rows.length - 1];
    if (last && sameRanges(last.ranges, ranges)) last.weekdays.push(weekday);
    else rows.push({ weekdays: [weekday], ranges });
  }
  return rows.map(({ weekdays, ranges }) => {
    const first = weekdayName(weekdays[0], locale);
    const lastDay = weekdayName(weekdays[weekdays.length - 1], locale);
    return {
      weekdays,
      label: weekdays.length === 1 ? first : `${first} – ${lastDay}`,
      hours: ranges.length ? ranges.map((r) => rangeLabel(r, locale)).join(', ') : 'Closed',
    };
  });
}

export interface OpenStatus {
  open: boolean;
  text: string;
}

/**
 * "Open now · until 8:00 p.m.", "Opens today at 10:00 a.m.", "Closed today · opens
 * Tuesday at 10:00 a.m." — from getOpeningTimes (real hours with closures),
 * never from the weekly pattern alone. `now` is the business-local "HH:MM".
 */
export function openStatus(days: readonly OpeningTimesDay[], today: string, now: string, locale: string): OpenStatus | null {
  const byDate = new Map(days.map((d) => [d.date, d.hours]));
  const todays = byDate.get(today);
  if (!todays) return null;

  const current = todays.find((r) => r.start <= now && now < r.end);
  if (current) {
    // Ranges that touch (10:00–14:00, 14:00–18:00) read as one.
    let end = current.end;
    for (const r of todays) if (r.start === end) end = r.end;
    if (end === '24:00') {
      const tomorrow = byDate.get(addDays(today, 1));
      const next = tomorrow?.find((r) => r.start === '00:00');
      if (next) end = next.end;
    }
    return { open: true, text: `Open now · until ${formatClockTime(end, locale)}` };
  }

  const later = todays.find((r) => r.start > now);
  if (later) {
    const earlier = todays.some((r) => r.end <= now);
    return { open: false, text: `${earlier ? 'Reopens' : 'Opens'} today at ${formatClockTime(later.start, locale)}` };
  }

  for (let i = 1; i <= 13; i++) {
    const date = addDays(today, i);
    const hours = byDate.get(date);
    if (!hours) break;
    if (hours.length) {
      const when = i === 1 ? 'tomorrow' : formatDate(date, locale, { weekday: 'long' });
      const label = i < 7 ? when : formatDate(date, locale, { weekday: 'long', month: 'long', day: 'numeric' });
      return { open: false, text: `Closed now · opens ${label} at ${formatClockTime(hours[0].start, locale)}` };
    }
  }
  return { open: false, text: 'Closed now' };
}

export interface HoursChange {
  date: string;
  label: string;
  hours: string;
}

/** Dates in the loaded range whose real hours differ from the weekly pattern (closures, short days). */
export function upcomingChanges(
  days: readonly OpeningTimesDay[],
  weekly: readonly OpeningHoursInterval[],
  weekdayOf: (date: string) => number,
  locale: string,
): HoursChange[] {
  return days
    .filter((day) => !sameRanges([...day.hours].sort((a, b) => a.start.localeCompare(b.start)), rangesFor(weekdayOf(day.date), weekly)))
    .map((day) => ({
      date: day.date,
      label: formatDate(day.date, locale, { weekday: 'long', month: 'long', day: 'numeric' }),
      hours: day.hours.length ? day.hours.map((r) => rangeLabel(r, locale)).join(', ') : 'Closed',
    }));
}
