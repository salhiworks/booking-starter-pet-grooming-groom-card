import type { RefObject } from 'react';
import { formatClockTime, formatDate, timeZoneLabel } from '@profitstudio/booking-engine';
import type { BookingConfirmation, Business } from '@profitstudio/booking-engine';
import { ContactInstead } from './ContactInstead';

export type Outcome =
  | { kind: 'booked'; confirmation: BookingConfirmation; email: string }
  | { kind: 'preview' }
  | { kind: 'limit' };

interface DoneProps {
  outcome: Outcome;
  business: Business;
  headingRef: RefObject<HTMLHeadingElement | null>;
  onAgain: () => void;
}

/** Shown only after verifyBooking answered ok: true — or, honestly, after PREVIEW_MODE. */
export function Done({ outcome, business, headingRef, onAgain }: DoneProps) {
  if (outcome.kind === 'preview') {
    return (
      <div className="done done--preview">
        <h2 className="step-title" tabIndex={-1} ref={headingRef} data-step-heading="">
          Preview — nothing was saved
        </h2>
        <p>
          This site is running on sample data, so no email was sent and no appointment was stored. Once the studio's booking system is
          connected, clients see their confirmation here.
        </p>
        <button type="button" className="button button--quiet" onClick={onAgain}>
          Start again
        </button>
      </div>
    );
  }

  if (outcome.kind === 'limit') {
    return (
      <div className="done">
        <h2 className="step-title" tabIndex={-1} ref={headingRef} data-step-heading="">
          You already have appointments booked with us
        </h2>
        <ContactInstead
          business={business}
          title="Let's find a time together"
          text="This email address already has as many upcoming appointments as we can hold online, so we couldn't add another and the time was released. Call or email the studio and we'll gladly help."
        />
      </div>
    );
  }

  const { confirmation, email } = outcome;
  const pending = confirmation.status === 'pending';
  const { locale } = business;
  return (
    <div className="done">
      <p className="done__mark" aria-hidden="true" />
      <h2 className="step-title" tabIndex={-1} ref={headingRef} data-step-heading="">
        {pending ? 'Request received — we’ll confirm your appointment shortly.' : 'Your appointment is booked.'}
      </h2>
      <p>
        {__BOOKING_DEMO__ ? (
          // Live Demo build only: no email exists to promise.
          <>
            This is a demo, so no email is sent.{' '}
            {pending ? 'Your request is waiting in the demo dashboard — confirm it there as the studio.' : 'Your appointment is in the demo dashboard.'}{' '}
            <a href="/admin/#bookings">Open the demo dashboard</a>
          </>
        ) : pending ? (
          `We're holding the time for you while the studio confirms. We'll email ${email} as soon as it's confirmed.`
        ) : (
          `A confirmation is on its way to ${email}.`
        )}
      </p>
      {pending && (
        <p className="done__note">
          We read your notes about your dog first: if the coat needs more time or a different price, we tell you before the
          appointment — never after.
        </p>
      )}
      <dl className="done__details">
        <div>
          <dt>Service</dt>
          <dd>{confirmation.serviceName}</dd>
        </div>
        <div>
          <dt>Date</dt>
          <dd>{formatDate(confirmation.date, locale, { weekday: 'long', month: 'long', day: 'numeric' })}</dd>
        </div>
        <div>
          <dt>Time</dt>
          <dd>
            {formatClockTime(confirmation.time, locale)}{' '}
            <span className="summary__zone">{timeZoneLabel(confirmation.timezone, locale)}</span>
          </dd>
        </div>
        <div>
          <dt>Reference</dt>
          <dd className="done__reference">{confirmation.reference}</dd>
        </div>
      </dl>
      <button type="button" className="button button--quiet" onClick={onAgain}>
        Book another appointment
      </button>
    </div>
  );
}
