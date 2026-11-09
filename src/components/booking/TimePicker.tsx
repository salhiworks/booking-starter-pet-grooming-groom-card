import { formatClockTime, formatDate, groupSlotsByPartOfDay, nextAvailableDay } from '@profitstudio/booking-engine';
import type { AvailabilityDay, PartOfDay, Slot } from '@profitstudio/booking-engine';
import type { MouseEvent } from 'react';
import { reducedMotion } from './details';

/** Keep the chosen time in view above the pinned Continue bar (the sheet's scroll-padding-bottom). */
function keepInView(event: MouseEvent<HTMLButtonElement>) {
  const button = event.currentTarget;
  requestAnimationFrame(() => button.scrollIntoView({ block: 'nearest', behavior: reducedMotion() ? 'auto' : 'smooth' }));
}

const PART_LABEL: Record<PartOfDay, string> = { morning: 'Morning', afternoon: 'Afternoon', evening: 'Evening' };

interface TimePickerProps {
  day: AvailabilityDay | null;
  days: AvailabilityDay[];
  monthLabel: string;
  /** The part of the day the guest last chose (kept from day to day when it has times). */
  part: PartOfDay;
  onPart: (part: PartOfDay) => void;
  selected: Slot | null;
  onSelect: (slot: Slot) => void;
  onJump: (date: string) => void;
  onNextMonth: (() => void) | null;
  locale: string;
}

/**
 * The server's slots for one day, grouped Morning / Afternoon / Evening. Labels use the
 * server's business-local `slot.time`, so they never depend on the browser's time-zone data.
 */
export function TimePicker({ day, days, monthLabel, part, onPart, selected, onSelect, onJump, onNextMonth, locale }: TimePickerProps) {
  if (!day) {
    return (
      <div className="day-state">
        <p className="day-state__lead">There are no open times in {monthLabel}.</p>
        {onNextMonth && (
          <button type="button" className="link-button" onClick={onNextMonth}>
            See next month
          </button>
        )}
      </div>
    );
  }

  const dateLabel = formatDate(day.date, locale, { weekday: 'long', month: 'long', day: 'numeric' });

  if (day.status !== 'available' || day.slots.length === 0) {
    const next = nextAvailableDay(days, day.date);
    const lead =
      day.status === 'closed'
        ? `The studio is closed on ${dateLabel}.`
        : day.status === 'full'
          ? `${dateLabel} is fully booked.`
          : `${dateLabel} can't be booked online.`;
    return (
      <div className="day-state">
        <p className="day-state__lead">{lead}</p>
        {next ? (
          <p>
            The next open day is {formatDate(next.date, locale, { weekday: 'long', month: 'long', day: 'numeric' })}.{' '}
            <button type="button" className="link-button" onClick={() => onJump(next.date)}>
              Show {formatDate(next.date, locale, { weekday: 'long' })}
            </button>
          </p>
        ) : onNextMonth ? (
          <p>
            There are no more open days in {monthLabel}.{' '}
            <button type="button" className="link-button" onClick={onNextMonth}>
              See next month
            </button>
          </p>
        ) : (
          <p>There are no other open times online right now — please call or email the studio.</p>
        )}
      </div>
    );
  }

  const groups = groupSlotsByPartOfDay(day.slots);
  const active = groups.find((g) => g.part === part && g.slots.length > 0) ?? groups.find((g) => g.slots.length > 0) ?? groups[0];

  return (
    <div className="times-block">
      <div className="parts" role="group" aria-label="Part of the day">
        {groups.map((group) => (
          <button
            type="button"
            key={group.part}
            className="part"
            aria-pressed={group.part === active.part}
            disabled={group.slots.length === 0}
            onClick={() => onPart(group.part)}
          >
            <span>{PART_LABEL[group.part]}</span>
            <span className="part__count">
              {group.slots.length}
              <span className="sr-only"> {group.slots.length === 1 ? 'time' : 'times'}</span>
            </span>
          </button>
        ))}
      </div>
      <ul className="times" role="list" aria-label={`${PART_LABEL[active.part]} times on ${dateLabel}`}>
        {active.slots.map((slot) => (
          <li key={slot.startsAt}>
            <button
              type="button"
              className="time"
              aria-pressed={selected?.startsAt === slot.startsAt}
              onClick={(event) => {
                onSelect(slot);
                keepInView(event);
              }}
            >
              {formatClockTime(slot.time, locale)}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
