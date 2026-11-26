// The engine's booking answers, read strictly (Booking Engine 2.0.0
// contract, the version every starter pins).
//
//   status 'confirmed'        → the appointment is booked
//   status 'pending'          → a request the business will confirm or decline
//   anything else, or the error BOOKING_INACTIVE
//                             → NOT an appointment: the request was declined,
//                               cancelled or not confirmed in time
//
// Never treat "not pending" as booked. This file is identical in every starter
// (scripts/check-booking-status.mjs).
import type { BookingConfirmation, EngineError } from '@profitstudio/booking-engine';

export type BookingAnswer = 'confirmed' | 'pending' | 'inactive';

export const INACTIVE_TITLE = 'This request is no longer active';
export const INACTIVE_TEXT = `${INACTIVE_TITLE}. Please choose a new time or contact the business.`;

/** How to describe a verified booking: only 'confirmed' is booked, only 'pending' is a request. */
export function answerOf(confirmation: Pick<BookingConfirmation, 'status'>): BookingAnswer {
  const status: string = confirmation.status;
  if (status === 'confirmed') return 'confirmed';
  if (status === 'pending') return 'pending';
  return 'inactive';
}

/** BOOKING_INACTIVE: the code was accepted earlier, but the booking is no longer active. */
export function isInactive(error: Pick<EngineError, 'code'>): boolean {
  return (error.code as string) === 'BOOKING_INACTIVE';
}

/** The booking's reference when the engine names it (BOOKING_INACTIVE), else null. */
export function referenceOf(error: EngineError): string | null {
  const reference = (error as { reference?: unknown }).reference;
  return typeof reference === 'string' && reference ? reference : null;
}

/** What the visitor reads when a request is no longer active. */
export function inactiveText(reference: string | null): string {
  return reference ? `${INACTIVE_TEXT} Your reference: ${reference}.` : INACTIVE_TEXT;
}

/** The same, under a heading that already says INACTIVE_TITLE. */
export function inactiveNext(reference: string | null): string {
  const next = 'Please choose a new time or contact the business.';
  return reference ? `${next} Your reference: ${reference}.` : next;
}
