import { useEffect, useRef, useState } from 'react';
import type { KeyboardEvent } from 'react';
import { addDays, addMonths, formatDate, isFewLeft, monthGrid, startOfWeek } from '@profitstudio/booking-engine';
import type { AvailabilityDay, Weekday } from '@profitstudio/booking-engine';
import { reducedMotion } from './details';

interface DayPickerProps {
  month: string;
  minMonth: string;
  maxMonth: string;
  weekStart: Weekday;
  /** The loaded month (null while it loads). */
  days: AvailabilityDay[] | null;
  today: string;
  selected: string | null;
  locale: string;
  onSelect: (date: string) => void;
  onMonth: (month: string) => void;
}

/** "Wednesday, November 4, 2 times left" — the date and its status, for screen readers. */
function dayLabel(date: string, day: AvailabilityDay | undefined, today: string, locale: string): string {
  const name = formatDate(date, locale, { weekday: 'long', month: 'long', day: 'numeric' });
  const prefix = date === today ? `Today, ${name}` : name;
  if (!day) return `${prefix}, loading`;
  switch (day.status) {
    case 'available':
      return isFewLeft(day) ? `${prefix}, ${day.slots.length} ${day.slots.length === 1 ? 'time' : 'times'} left` : `${prefix}, open`;
    case 'full':
      return `${prefix}, fully booked`;
    case 'closed':
      return `${prefix}, closed`;
    default:
      return `${prefix}, not bookable online`;
  }
}

function Mark({ day }: { day: AvailabilityDay | undefined }) {
  if (!day) return null;
  if (day.status === 'available') {
    return isFewLeft(day) ? <span className="day__few">{day.slots.length} left</span> : <span className="day__dot" />;
  }
  if (day.status === 'full') return <span className="day__word">Full</span>;
  if (day.status === 'closed') return <span className="day__word">Closed</span>;
  return null;
}

function Chevron({ direction }: { direction: 'left' | 'right' }) {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">
      <path
        d={direction === 'left' ? 'M14.5 5.5 8 12l6.5 6.5' : 'M9.5 5.5 16 12l-6.5 6.5'}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/**
 * The calm calendar: a month grid from 720 px, a horizontal day rail on phones.
 * Both reshape one getAvailability call per visible month (monthGrid) and never
 * compute availability themselves.
 */
export function DayPicker(props: DayPickerProps) {
  const { month, minMonth, maxMonth, days, today, selected, locale, onSelect, onMonth } = props;
  const byDate = new Map((days ?? []).map((d) => [d.date, d]));
  const monthLabel = formatDate(`${month}-01`, locale, { month: 'long', year: 'numeric' });
  const soonest = (days ?? []).filter((d) => d.status === 'available' && d.date >= today).slice(0, 3);
  const loading = days === null;

  return (
    <div className="cal" aria-busy={loading || undefined}>
      <div className="cal__head">
        <button
          type="button"
          className="icon-button"
          onClick={() => onMonth(addMonths(month, -1))}
          disabled={month <= minMonth}
          aria-label="Previous month"
        >
          <Chevron direction="left" />
        </button>
        <p className="cal__month" aria-live="polite">
          {monthLabel}
        </p>
        <button
          type="button"
          className="icon-button"
          onClick={() => onMonth(addMonths(month, 1))}
          disabled={month >= maxMonth}
          aria-label="Next month"
        >
          <Chevron direction="right" />
        </button>
      </div>

      {soonest.length > 0 && (
        <div className="cal__soonest">
          <span className="cal__soonest-label">Next open days</span>
          {soonest.map((d) => (
            <button
              type="button"
              key={d.date}
              className="soon-chip"
              aria-pressed={d.date === selected}
              onClick={() => onSelect(d.date)}
            >
              {d.date === today ? 'Today' : formatDate(d.date, locale, { weekday: 'short', month: 'short', day: 'numeric' })}
            </button>
          ))}
        </div>
      )}

      <MonthGrid {...props} byDate={byDate} monthLabel={monthLabel} />
      <DayRail
        month={month}
        weekStart={props.weekStart}
        byDate={byDate}
        loading={loading}
        today={today}
        selected={selected}
        locale={locale}
        onSelect={onSelect}
        monthLabel={monthLabel}
      />
    </div>
  );
}

interface GridProps extends DayPickerProps {
  byDate: Map<string, AvailabilityDay>;
  monthLabel: string;
}

function MonthGrid({ month, minMonth, maxMonth, weekStart, days, today, selected, locale, onSelect, onMonth, byDate, monthLabel }: GridProps) {
  const grid = monthGrid(month, weekStart);
  const dates = grid.weeks.flat();
  const buttons = useRef(new Map<string, HTMLButtonElement>());
  const [focusDate, setFocusDate] = useState<string | null>(null);
  const landOn = useRef<'first' | 'last' | null>(null);

  const selectable = (date: string) => {
    const day = byDate.get(date);
    return !!day && day.status !== 'unavailable';
  };
  // One tab stop in the grid (roving tabindex); focusing a day makes it the stop.
  const tabStop = [focusDate, selected, today, ...dates].find((d): d is string => !!d && dates.includes(d) && selectable(d)) ?? null;

  // After Page Up/Down (or an arrow past the edge) the next month loads; then focus its first/last open day.
  useEffect(() => {
    if (!days || !landOn.current) return;
    const open = days.filter((d) => d.status !== 'unavailable' && d.date.startsWith(month));
    const target = landOn.current === 'first' ? open[0] : open[open.length - 1];
    landOn.current = null;
    if (target) buttons.current.get(target.date)?.focus();
  }, [days, month]);

  const move = (target: string | null, direction: 1 | -1) => {
    if (target) {
      buttons.current.get(target)?.focus();
    } else if (direction > 0 && month < maxMonth) {
      landOn.current = 'first';
      onMonth(addMonths(month, 1));
    } else if (direction < 0 && month > minMonth) {
      landOn.current = 'last';
      onMonth(addMonths(month, -1));
    }
  };

  const walk = (from: string, delta: number): string | null => {
    for (let d = addDays(from, delta); d >= grid.from && d <= grid.to; d = addDays(d, delta)) {
      if (selectable(d)) return d;
    }
    return null;
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTableElement>) => {
    const current = (event.target as HTMLElement).dataset?.date;
    if (!current) return;
    switch (event.key) {
      case 'ArrowLeft':
        move(walk(current, -1), -1);
        break;
      case 'ArrowRight':
        move(walk(current, 1), 1);
        break;
      case 'ArrowUp':
        move(walk(current, -7), -1);
        break;
      case 'ArrowDown':
        move(walk(current, 7), 1);
        break;
      case 'Home': {
        const start = startOfWeek(current, weekStart);
        move([0, 1, 2, 3, 4, 5, 6].map((i) => addDays(start, i)).find(selectable) ?? null, -1);
        break;
      }
      case 'End': {
        const start = startOfWeek(current, weekStart);
        move([6, 5, 4, 3, 2, 1, 0].map((i) => addDays(start, i)).find(selectable) ?? null, 1);
        break;
      }
      case 'PageUp':
        move(null, -1);
        break;
      case 'PageDown':
        move(null, 1);
        break;
      default:
        return;
    }
    event.preventDefault();
  };

  return (
    <table className="cal__grid" aria-label={monthLabel} onKeyDown={onKeyDown}>
      <thead>
        <tr>
          {grid.weeks[0].map((date) => (
            <th scope="col" key={date} abbr={formatDate(date, locale, { weekday: 'long' })}>
              {formatDate(date, locale, { weekday: 'short' })}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {grid.weeks.map((week) => (
          <tr key={week[0]}>
            {week.map((date) => {
              const day = byDate.get(date);
              const outside = !date.startsWith(month);
              const canPick = selectable(date);
              return (
                <td key={date}>
                  <button
                    type="button"
                    className="day"
                    data-date={date}
                    data-status={day?.status ?? 'loading'}
                    data-outside={outside || undefined}
                    data-today={date === today || undefined}
                    aria-pressed={date === selected}
                    aria-label={dayLabel(date, day, today, locale)}
                    disabled={!canPick}
                    tabIndex={date === tabStop ? 0 : -1}
                    ref={(el) => {
                      if (el) buttons.current.set(date, el);
                      else buttons.current.delete(date);
                    }}
                    onFocus={() => setFocusDate(date)}
                    onClick={() => onSelect(date)}
                  >
                    <span className="day__num">{Number(date.slice(8))}</span>
                    <span className="day__mark" aria-hidden="true">
                      <Mark day={day} />
                    </span>
                  </button>
                </td>
              );
            })}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

interface RailProps {
  month: string;
  weekStart: Weekday;
  byDate: Map<string, AvailabilityDay>;
  loading: boolean;
  today: string;
  selected: string | null;
  locale: string;
  monthLabel: string;
  onSelect: (date: string) => void;
}

/** Phones: the month's bookable days in a row, starting from the next open days. */
function DayRail({ month, weekStart, byDate, loading, today, selected, locale, monthLabel, onSelect }: RailProps) {
  const list = useRef<HTMLUListElement>(null);
  const grid = monthGrid(month, weekStart);
  const dates = grid.weeks.flat().filter((d) => {
    const day = byDate.get(d);
    return !!day && day.status !== 'unavailable' && d >= today;
  });
  const tabStop = dates.includes(selected ?? '') ? selected : (dates[0] ?? null);

  // Keep the chosen day in view — horizontally only, never scrolling the page.
  useEffect(() => {
    const el = list.current;
    if (!el || !selected) return;
    const card = el.querySelector<HTMLElement>(`[data-date="${selected}"]`);
    if (!card) return;
    el.scrollTo({ left: card.offsetLeft - (el.clientWidth - card.offsetWidth) / 2, behavior: reducedMotion() ? 'auto' : 'smooth' });
  }, [selected, dates.length]);

  const onKeyDown = (event: KeyboardEvent<HTMLUListElement>) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
    const current = (event.target as HTMLElement).dataset?.date;
    const index = current ? dates.indexOf(current) : -1;
    const next = dates[index + (event.key === 'ArrowRight' ? 1 : -1)];
    if (!next) return;
    event.preventDefault();
    list.current?.querySelector<HTMLElement>(`[data-date="${next}"]`)?.focus();
  };

  if (loading) {
    return (
      <div className="rail" aria-hidden="true">
        <ul className="rail__list">
          {[0, 1, 2, 3, 4, 5].map((i) => (
            <li key={i}>
              <span className="day-card day-card--skeleton" />
            </li>
          ))}
        </ul>
      </div>
    );
  }

  if (dates.length === 0) {
    return (
      <div className="rail">
        <p className="quiet-state">No days left to book in {monthLabel}.</p>
      </div>
    );
  }

  return (
    <div className="rail">
      <ul className="rail__list" ref={list} aria-label={`Days in ${monthLabel}`} onKeyDown={onKeyDown}>
        {dates.map((date) => {
          const day = byDate.get(date);
          return (
            <li key={date}>
              <button
                type="button"
                className="day-card"
                data-date={date}
                data-status={day?.status}
                data-today={date === today || undefined}
                aria-pressed={date === selected}
                aria-label={dayLabel(date, day, today, locale)}
                tabIndex={date === tabStop ? 0 : -1}
                onClick={() => onSelect(date)}
              >
                <span className="day-card__weekday">{date === today ? 'Today' : formatDate(date, locale, { weekday: 'short' })}</span>
                <span className="day-card__num">{Number(date.slice(8))}</span>
                <span className="day-card__mark" aria-hidden="true">
                  <Mark day={day} />
                </span>
              </button>
            </li>
          );
        })}
      </ul>
    </div>
  );
}
