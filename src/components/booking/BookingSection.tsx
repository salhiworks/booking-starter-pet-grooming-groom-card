import type { Business, Service } from '@profitstudio/booking-engine';
import type { StartBooking } from '../../App';
import type { SiteValues } from '../../lib/content';
import { engine } from '../../lib/engine';
import type { Resource } from '../../lib/resource';
import { Emphasis } from '../Emphasis';
import { bookLink } from '../../lib/bookLink';
import { Notice } from '../Notice';
import { ContactInstead } from './ContactInstead';

interface BookingSectionProps {
  values: SiteValues;
  business: Resource<Business>;
  services: Resource<Service[]>;
  onRetry: () => void;
  onBook: StartBooking;
}

/**
 * #book on the page: how booking works and the button that opens the booking
 * sheet — or, while online booking is not possible, why, with the studio's
 * contact details. Every Book button lands here in that case.
 */
export function BookingSection({ values, business, services, onRetry, onBook }: BookingSectionProps) {
  return (
    <section id="book" className="section book" aria-labelledby="book-title">
      <div className="page book__grid">
        <header className="section-head book__head">
          <p className="eyebrow eyebrow--signal book__eyebrow">Book online</p>
          <h2 id="book-title">
            <Emphasis text={values['book.title']} />
          </h2>
          {values['book.intro'] && <p className="section-intro">{values['book.intro']}</p>}
        </header>
        <div className="book__body">
          <BookingBody values={values} business={business} services={services} onRetry={onRetry} onBook={onBook} />
        </div>
      </div>
    </section>
  );
}

function BookingBody({ values, business, services, onRetry, onBook }: BookingSectionProps) {
  const notConfigured =
    engine.mode === 'unconfigured' ||
    (business.status === 'error' && business.error.code === 'NOT_CONFIGURED') ||
    (services.status === 'error' && services.error.code === 'NOT_CONFIGURED');
  if (notConfigured) {
    return (
      <ContactInstead
        business={business.status === 'ready' ? business.data : null}
        title="Online booking is not available yet"
        text="We're setting up online booking. In the meantime, please call or email the studio to book an appointment."
      />
    );
  }

  if (business.status === 'loading' || services.status === 'loading') {
    return (
      <div className="book__loading" aria-busy="true">
        <p className="sr-only" role="status">
          Loading…
        </p>
        <span className="skeleton skeleton--row" aria-hidden="true" />
        <span className="skeleton skeleton--row" aria-hidden="true" />
        <span className="skeleton skeleton--row" aria-hidden="true" />
      </div>
    );
  }

  const failed = business.status === 'error' ? business.error : services.status === 'error' ? services.error : null;
  if (failed) {
    if (failed.code === 'SCHEMA_MISSING' || failed.code === 'SCHEMA_INCOMPATIBLE') {
      return (
        <ContactInstead
          business={business.status === 'ready' ? business.data : null}
          title="Online booking is temporarily unavailable"
          text="Please call or email the studio and we'll find you a time."
        />
      );
    }
    return (
      <Notice tone="error" action={{ label: 'Try again', onClick: onRetry }}>
        <p>{failed.code === 'NETWORK' ? "We couldn't reach the booking system. Please check your connection." : "We couldn't load the booking calendar just now."}</p>
      </Notice>
    );
  }

  if (business.status !== 'ready' || services.status !== 'ready') return null;

  if (!business.data.policies.onlineBookingEnabled) {
    return (
      <ContactInstead
        business={business.data}
        title="Book by phone or email for now"
        text="Online booking is switched off at the moment. Call or email the studio and we'll find you a time."
      />
    );
  }

  if (services.data.length === 0) {
    return (
      <ContactInstead
        business={business.data}
        title="Online booking opens soon"
        text="Our services aren't listed online yet. Call or email the studio and we'll find you a time."
      />
    );
  }

  return (
    <div className="book__how">
      <ol className="book__steps">
        <li>
          <span className="book__n" aria-hidden="true">1</span>
          <span className="book__step">Choose a service</span>
          <span className="book__text">One dog per booking. Each service shows the dog size, the time we book your dog in and the price.</span>
        </li>
        <li>
          <span className="book__n" aria-hidden="true">2</span>
          <span className="book__step">Pick a time</span>
          <span className="book__text">Only drop-off times when the table is really free are shown, in the studio’s local time.</span>
        </li>
        <li>
          <span className="book__n" aria-hidden="true">3</span>
          {business.data.policies.autoConfirm ? (
            <>
              <span className="book__step">Confirm it’s you</span>
              <span className="book__text">
                {__BOOKING_DEMO__
                  ? 'In this demo no email is sent: any 6 digits confirm it.'
                  : 'We email you a 6-digit code — no account, no password.'}
              </span>
            </>
          ) : (
            <>
              {/* The studio confirms each booking: the last step sends a request, and says so. */}
              <span className="book__step">Send your request</span>
              <span className="book__text">
                {__BOOKING_DEMO__
                  ? 'In this demo no email is sent: any 6 digits send it, and you confirm it yourself in the dashboard.'
                  : 'A 6-digit email code sends it — no account needed. We read your notes about your dog and confirm by email, with any change to time or price.'}
              </span>
            </>
          )}
        </li>
      </ol>
      <a className="button button--large button--on-signal" href="#book" onClick={bookLink(onBook)}>
        {values['hero.cta']}
      </a>
    </div>
  );
}
