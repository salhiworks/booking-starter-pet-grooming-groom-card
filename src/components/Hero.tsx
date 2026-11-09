import type { Business, Service } from '@profitstudio/booking-engine';
import type { StartBooking } from '../App';
import type { SiteValues } from '../lib/content';
import type { OpenStatus } from '../lib/hours';
import type { Resource } from '../lib/resource';
import { kinds, shortPrice } from '../lib/services';
import { bookLink } from '../lib/bookLink';
import { Emphasis } from './Emphasis';
import { GroomCard } from './GroomCard';
import { Photo } from './Photo';

/** Keep in sync with the hero preloads in index.html. */
export const HERO_SIZES = '(min-width: 960px) 40vw, 100vw';

/**
 * Phones get a wider crop of the same moment when the site's own default photo is
 * shown: the first screen there is short, and the upright frame would push the
 * headline and the Book button down. An owner's photo is used as it is, everywhere.
 */
const DEFAULT_HERO = '/photos/hero-paw-1200.webp';
const PHONE_CROP = { key: '/photos/hero-paw-wide-800.webp', media: '(max-width: 959px)', sizes: '100vw' };

interface HeroProps {
  values: SiteValues;
  status: OpenStatus | null;
  services: Resource<Service[]>;
  business: Business | null;
  /** Fields the owner has set — the photo's "Sample" label disappears once they replace it. */
  ownerFields: string[];
  onBook: StartBooking;
}

/**
 * Plain facts from the engine: the lowest full-groom price (or, without full grooms,
 * the lowest price of anything), and the number of services. Nothing is invented.
 */
function menuFacts(services: Resource<Service[]>, business: Business | null) {
  if (services.status !== 'ready' || services.data.length === 0) return null;
  const locale = business?.locale ?? 'en-US';
  const cheapest = (list: Service[]) => {
    const priced = list.filter((s) => s.priceCents !== null);
    return priced.length ? priced.reduce((a, b) => ((a.priceCents ?? 0) <= (b.priceCents ?? 0) ? a : b)) : null;
  };
  const full = kinds(services.data).find((k) => k.id === 'full');
  const fullCheapest = full ? cheapest(full.services) : null;
  const any = cheapest(services.data);
  const price = fullCheapest ?? any;
  return {
    label: fullCheapest ? 'Full grooms' : 'Services',
    price: price ? shortPrice({ ...price, priceFrom: true }, locale) : null,
    count: services.data.length,
  };
}

/**
 * The first screen: the words on the left — a soft serif headline, one sentence
 * about the studio, Book a groom and a link to the prices — and on the right a
 * calm dog on the table in daylight, with the groom card tucked over the photo's
 * lower corner. Phones: a wider crop of the photo first, then the headline and
 * the Book button inside the first screen, then the words and the card.
 */
export function Hero({ values, ownerFields, status, services, business, onBook }: HeroProps) {
  const sample = !ownerFields.includes('hero.photo');
  const photo = values['hero.photo'];
  const facts = menuFacts(services, business);
  const pricesLabel = values['hero.pricesLabel'].trim();
  return (
    <section className={`hero ${photo ? '' : 'hero--text-only'}`} id="top" aria-labelledby="hero-title">
      <div className="page hero__inner">
        {photo && (
          <figure className="hero__visual">
            <Photo
              image={photo}
              sizes={HERO_SIZES}
              priority
              className="hero__photo"
              small={photo.src === DEFAULT_HERO ? PHONE_CROP : undefined}
            />
            {sample && <span className="tag tag--on-photo">Sample</span>}
            <GroomCard values={values} className="hero__card hero__card--desk" />
          </figure>
        )}

        <div className="hero__text">
          {values['hero.eyebrow'] && <p className="eyebrow hero__eyebrow hero__enter">{values['hero.eyebrow']}</p>}
          <h1 id="hero-title" className="hero__title hero__enter">
            <Emphasis text={values['hero.title']} />
          </h1>
          {values['hero.lede'] && <p className="hero__lede hero__enter">{values['hero.lede']}</p>}
          <div className="hero__actions hero__enter">
            <a className="button button--large" href="#book" onClick={bookLink(onBook)}>
              {values['hero.cta']}
              <span className="button__arrow" aria-hidden="true">
                →
              </span>
            </a>
            {pricesLabel && (
              <a className="hero__prices" href="#services">
                {pricesLabel}
                <span aria-hidden="true">&nbsp;↓</span>
              </a>
            )}
          </div>
          {(facts || status) && (
            <dl className="hero__facts hero__enter">
              {facts?.price && (
                <div>
                  <dt>{facts.label}</dt>
                  <dd>{facts.price}</dd>
                </div>
              )}
              {facts && (
                <div>
                  <dt>On the menu</dt>
                  <dd>
                    {facts.count} {facts.count === 1 ? 'service' : 'services'}
                  </dd>
                </div>
              )}
              {status && (
                <div className="hero__fact-status">
                  <dt>Today</dt>
                  <dd className="open-status" data-open={status.open}>
                    <span className="open-status__dot" aria-hidden="true" />
                    {status.text}
                  </dd>
                </div>
              )}
            </dl>
          )}
          <GroomCard values={values} className="hero__card hero__card--phone" />
        </div>
      </div>
    </section>
  );
}
