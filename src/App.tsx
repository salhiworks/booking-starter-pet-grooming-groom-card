import { useCallback, useEffect, useState } from 'react';
import { Banners } from './components/BannerStack';
import { Footer } from './components/Footer';
import { Header } from './components/Header';
import { GoodToKnow } from './components/GoodToKnow';
import { Hero } from './components/Hero';
import { Services } from './components/Services';
import { Gallery } from './components/Gallery';
import { Experience } from './components/Experience';
import { Studio } from './components/Studio';
import { Visit } from './components/Visit';
import { BookingSection } from './components/booking/BookingSection';
import { BookingSheet } from './components/booking/BookingSheet';
import type { BookingIntent } from './components/booking/BookingFlow';
import { useSiteContent } from './lib/content';
import { engine } from './lib/engine';
import { useEngineResource } from './lib/resource';
import { useOpening } from './lib/useOpening';

// Module-level so the resource hooks get stable loaders.
const loadBusiness = () => engine.getBusiness();
const loadServices = () => engine.listServices();

const BOOK_HASH = '#book';
const isBookingEntry = () => Boolean((history.state as { booking?: boolean } | null)?.booking);
const withoutHash = () => `${location.pathname}${location.search}`;

/** "Book" from anywhere on the page: open the sheet, optionally with a service chosen. */
export type StartBooking = (serviceId?: string | null) => void;

/**
 * One page of sections, plus the booking sheet over it at #book. No routes.
 * The sheet is a modal <dialog>; Back, Esc, ✕ or a click beside it closes it,
 * and the flow inside stays mounted, so every choice is still there when it opens again.
 */
export function App() {
  const content = useSiteContent();
  const values = content.values;
  const [business, reloadBusiness] = useEngineResource(loadBusiness);
  const [services, reloadServices] = useEngineResource(loadServices);
  const opening = useOpening(business.status === 'ready' ? business.data : null);
  const [intent, setIntent] = useState<BookingIntent | null>(null);

  // Online booking is known not to be possible (paused, nothing to book, not set
  // up, a load problem): every Book action leads to the #book section, which says
  // how to book instead. While the data is still loading the sheet opens and shows
  // its own loading state.
  const bookingOff =
    engine.mode === 'unconfigured' ||
    business.status === 'error' ||
    services.status === 'error' ||
    (business.status === 'ready' && !business.data.policies.onlineBookingEnabled) ||
    (services.status === 'ready' && services.data.length === 0);

  // Arriving at /#book opens the sheet straight away (unless booking is off).
  const [open, setOpen] = useState(() => location.hash === BOOK_HASH);
  const sheetOpen = open && !bookingOff;

  const showSheet = useCallback(() => {
    // One history entry for the sheet, so Back (or a phone's back gesture) closes it.
    if (!isBookingEntry()) history.pushState({ ...(history.state as object | null), booking: true }, '', BOOK_HASH);
    setOpen(true);
  }, []);

  const startBooking = useCallback<StartBooking>(
    (serviceId) => {
      if (bookingOff) {
        const section = document.getElementById('book');
        const heading = section?.querySelector<HTMLElement>('#book-title') ?? null;
        if (heading && !heading.hasAttribute('tabindex')) heading.tabIndex = -1;
        (heading ?? section)?.focus({ preventScroll: true });
        const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        section?.scrollIntoView({ block: 'start', behavior: reduce ? 'auto' : 'smooth' });
        return;
      }
      setIntent((previous) => ({ serviceId: serviceId ?? null, nonce: (previous?.nonce ?? 0) + 1 }));
      showSheet();
    },
    [bookingOff, showSheet],
  );

  const close = useCallback(() => {
    if (isBookingEntry()) history.back();
    else {
      history.replaceState(history.state, '', withoutHash());
      setOpen(false);
    }
  }, []);

  // Back / forward through the sheet's history entry; #book typed or linked.
  useEffect(() => {
    const sync = () => setOpen(isBookingEntry() || location.hash === BOOK_HASH);
    window.addEventListener('popstate', sync);
    window.addEventListener('hashchange', sync);
    return () => {
      window.removeEventListener('popstate', sync);
      window.removeEventListener('hashchange', sync);
    };
  }, []);

  // A direct visit to /#book gets its own entry, so Back returns to the page, not away from the site.
  useEffect(() => {
    if (location.hash !== BOOK_HASH || isBookingEntry()) return;
    history.replaceState(history.state, '', withoutHash());
    history.pushState({ booking: true }, '', BOOK_HASH);
  }, []);

  const retryAll = useCallback(() => {
    reloadBusiness();
    reloadServices();
  }, [reloadBusiness, reloadServices]);

  const businessData = business.status === 'ready' ? business.data : null;

  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>
      <Banners content={content} preview={engine.mode === 'preview'} />
      <Header values={values} onBook={startBooking} />
      <main id="main" tabIndex={-1}>
        <Hero
          values={values}
          ownerFields={content.ownerFields}
          status={opening.status}
          services={services}
          business={businessData}
          onBook={startBooking}
        />
        <Services values={values} services={services} business={businessData} onRetry={reloadServices} onBook={startBooking} />
        <Gallery values={values} ownerFields={content.ownerFields} />
        <Experience values={values} ownerFields={content.ownerFields} />
        <Studio values={values} ownerFields={content.ownerFields} />
        <GoodToKnow values={values} ownerFields={content.ownerFields} />
        <BookingSection values={values} business={business} services={services} onRetry={retryAll} onBook={startBooking} />
        <Visit values={values} business={business} opening={opening} onRetry={reloadBusiness} />
      </main>
      <Footer values={values} business={businessData} onBook={startBooking} />
      <BookingSheet
        open={sheetOpen}
        onClose={close}
        values={values}
        business={business}
        services={services}
        intent={intent}
        onRetry={retryAll}
        onServicesStale={reloadServices}
      />
    </>
  );
}
