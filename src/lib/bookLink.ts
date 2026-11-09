import type { MouseEvent } from 'react';
import type { StartBooking } from '../App';

/** A Book link that opens the booking sheet (or, while booking is off, leads to #book). */
export function bookLink(onBook: StartBooking, serviceId?: string | null) {
  return (event: MouseEvent<HTMLAnchorElement>) => {
    event.preventDefault();
    onBook(serviceId ?? null);
  };
}
