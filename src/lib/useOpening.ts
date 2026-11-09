import { useEffect, useMemo, useState } from 'react';
import { addDays, localTimeLabel, todayInTimeZone, weekdayOf } from '@profitstudio/booking-engine';
import type { Business, OpeningTimesDay } from '@profitstudio/booking-engine';
import { engine } from './engine';
import { openStatus, upcomingChanges } from './hours';
import type { HoursChange, OpenStatus } from './hours';

const DAYS_AHEAD = 13;

/** The weekly pattern as dated days — only for databases without getOpeningTimes. */
function fromWeeklyPattern(business: Business, from: string): OpeningTimesDay[] {
  return Array.from({ length: DAYS_AHEAD + 1 }, (_, i) => {
    const date = addDays(from, i);
    const weekday = weekdayOf(date);
    return {
      date,
      hours: business.openingHours
        .filter((h) => h.weekday === weekday)
        .map(({ start, end }) => ({ start, end }))
        .sort((a, b) => a.start.localeCompare(b.start)),
    };
  });
}

export interface OpeningInfo {
  today: string | null;
  status: OpenStatus | null;
  changes: HoursChange[];
}

/** "Open now" and the next two weeks' changes, from the real opening times (with closures). */
export function useOpening(business: Business | null): OpeningInfo {
  const [now, setNow] = useState(() => Date.now());
  const [loaded, setLoaded] = useState<{ from: string; days: OpeningTimesDay[] } | null>(null);
  const timezone = business?.timezone ?? null;
  const today = timezone ? todayInTimeZone(timezone, new Date(now)) : null;

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!business || !today) return;
    let alive = true;
    void engine.getOpeningTimes({ from: today, to: addDays(today, DAYS_AHEAD) }).then((result) => {
      if (!alive) return;
      if (result.ok) setLoaded({ from: today, days: result.data.days });
      else if (result.error.code === 'SCHEMA_INCOMPATIBLE') setLoaded({ from: today, days: fromWeeklyPattern(business, today) });
      else setLoaded(null);
    });
    return () => {
      alive = false;
    };
  }, [business, today]);

  return useMemo<OpeningInfo>(() => {
    if (!business || !today || !loaded || loaded.from !== today) return { today, status: null, changes: [] };
    const nowLabel = localTimeLabel(now, business.timezone);
    return {
      today,
      status: openStatus(loaded.days, today, nowLabel, business.locale),
      changes: upcomingChanges(loaded.days, business.openingHours, weekdayOf, business.locale),
    };
  }, [business, today, loaded, now]);
}
