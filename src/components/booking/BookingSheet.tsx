import { useEffect, useRef, type FocusEvent, type MouseEvent } from 'react';
import type { Business, Service } from '@profitstudio/booking-engine';
import type { SiteValues } from '../../lib/content';
import { useModalDialog } from '../../lib/dialog';
import type { Resource } from '../../lib/resource';
import { plainText } from '../../lib/text';
import { Notice } from '../Notice';
import { BookingFlow } from './BookingFlow';
import type { BookingIntent } from './BookingFlow';
import { ContactInstead } from './ContactInstead';

interface BookingSheetProps {
  open: boolean;
  onClose: () => void;
  values: SiteValues;
  business: Resource<Business>;
  services: Resource<Service[]>;
  intent: BookingIntent | null;
  onRetry: () => void;
  onServicesStale: () => void;
}

/**
 * The booking as a sheet of paper over the page (a modal <dialog>): it rises from
 * the bottom on phones and fills the screen; from 900 px it slides in from the
 * right, wide enough for the calendar beside the appointment summary.
 */
export function BookingSheet({ open, onClose, values, business, services, intent, onRetry, onServicesStale }: BookingSheetProps) {
  const ref = useRef<HTMLDialogElement>(null);
  useModalDialog(ref, open, onClose);

  // Opening: the current step's heading takes focus.
  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      const dialog = ref.current;
      const target = dialog?.querySelector<HTMLElement>('[data-step-heading]') ?? dialog?.querySelector<HTMLElement>('[data-sheet-title]');
      target?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [open]);

  // A click on the dimmed page beside the sheet (the dialog itself) closes it.
  const onDialogClick = (event: MouseEvent<HTMLDialogElement>) => {
    if (event.target === event.currentTarget) onClose();
  };

  // A focused field is never left under the pinned submit / Continue bar (browsers
  // only partly honour scroll-padding when they scroll a focused field into view).
  const keepFieldClear = (event: FocusEvent<HTMLDivElement>) => {
    const field = event.target;
    if (!(field instanceof HTMLInputElement || field instanceof HTMLTextAreaElement || field instanceof HTMLSelectElement)) return;
    const body = event.currentTarget;
    requestAnimationFrame(() => {
      const bar = body.querySelector<HTMLElement>('.details .step-actions, .choice-bar');
      if (!bar || bar.contains(field)) return;
      const f = field.getBoundingClientRect();
      const b = bar.getBoundingClientRect();
      const room = 12;
      if (f.bottom > b.top - room && f.top < b.bottom) body.scrollBy({ top: f.bottom - b.top + room });
    });
  };

  const name = business.status === 'ready' ? business.data.name : null;

  return (
    <dialog ref={ref} className="sheet" aria-labelledby="sheet-title" onClick={onDialogClick}>
      <div className="sheet__panel">
        <header className="sheet__head">
          <div className="sheet__titles">
            {name && <p className="sheet__business">{name}</p>}
            <p className="sheet__title" id="sheet-title" tabIndex={-1} data-sheet-title="">
              {plainText(values['book.title'])}
            </p>
          </div>
          <button type="button" className="icon-button sheet__close" onClick={onClose}>
            <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true" focusable="false">
              <path d="M3 3l10 10M13 3 3 13" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
            <span className="sr-only">Close the booking</span>
          </button>
        </header>
        <div className="sheet__body" onFocus={keepFieldClear}>
          <SheetSurface business={business} services={services} intent={intent} onRetry={onRetry} onServicesStale={onServicesStale} />
        </div>
      </div>
    </dialog>
  );
}

function SheetSurface({ business, services, intent, onRetry, onServicesStale }: Omit<BookingSheetProps, 'open' | 'onClose' | 'values'>) {
  if (business.status === 'ready' && services.status === 'ready' && business.data.policies.onlineBookingEnabled && services.data.length > 0) {
    return <BookingFlow business={business.data} services={services.data} intent={intent} onServicesStale={onServicesStale} />;
  }
  if (business.status === 'loading' || services.status === 'loading') {
    return (
      <div className="flow flow--loading" aria-busy="true">
        <p className="sr-only" role="status">
          Loading the booking calendar…
        </p>
        <span className="skeleton skeleton--steps" aria-hidden="true" />
        <span className="skeleton skeleton--block" aria-hidden="true" />
      </div>
    );
  }
  const failed = business.status === 'error' ? business.error : services.status === 'error' ? services.error : null;
  if (failed && failed.code !== 'SCHEMA_MISSING' && failed.code !== 'SCHEMA_INCOMPATIBLE' && failed.code !== 'NOT_CONFIGURED') {
    return (
      <Notice tone="error" action={{ label: 'Try again', onClick: onRetry }}>
        <p>{failed.code === 'NETWORK' ? "We couldn't reach the booking system. Please check your connection." : "We couldn't load the booking calendar just now."}</p>
      </Notice>
    );
  }
  return (
    <ContactInstead
      business={business.status === 'ready' ? business.data : null}
      title="Book by phone or email for now"
      text="Online booking isn't available at the moment. Call or email the studio and we'll find you a time."
    />
  );
}
