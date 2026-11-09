import { useState } from 'react';
import type { Business, Service } from '@profitstudio/booking-engine';
import type { StartBooking } from '../App';
import { bookLink } from '../lib/bookLink';
import type { SiteValues } from '../lib/content';
import type { Resource } from '../lib/resource';
import { SIZES, durationLabel, durationSpoken, fitsSize, hasSizes, kinds, priceParts, splitDescription, splitName } from '../lib/services';
import type { SizeId } from '../lib/services';
import { Emphasis } from './Emphasis';
import { Notice } from './Notice';
import { SectionMark } from './SectionMark';

interface ServicesProps {
  values: SiteValues;
  services: Resource<Service[]>;
  business: Business | null;
  onRetry: () => void;
  onBook: StartBooking;
}

const SIZE_FIELD = { small: 'sizes.small', medium: 'sizes.medium', large: 'sizes.large' } as const;

/**
 * The grooming menu, straight from the engine: every name, time and price is the
 * one the booking uses. First the dog's size, as the tabs of an index card (All ·
 * Small · Medium · Large, with the owner's weight range on each) — choosing one only
 * filters the list, it never changes a price. Then the services in their kinds
 * (Full grooms, Baths & coat care, Puppies, Tidies & nails), each row with what it
 * includes, who it is for, the time we book the dog in, the price ("from" when it is
 * a starting price) and a Book button that opens the booking with it chosen. Under
 * the list, the owner's honest note about starting prices and coat condition.
 */
export function Services({ values, services, business, onRetry, onBook }: ServicesProps) {
  const locale = business?.locale ?? 'en-US';
  const [size, setSize] = useState<SizeId | null>(null);
  const all = services.status === 'ready' ? services.data : [];
  const sized = hasSizes(all);
  const activeSize = sized ? size : null;
  const groups = kinds(all.filter((s) => fitsSize(s, activeSize)));
  const shown = groups.reduce((n, g) => n + g.services.length, 0);
  const sizeLabel = activeSize ? SIZES.find((s) => s.id === activeSize)!.label.toLowerCase() : null;

  return (
    <section id="services" className="section services" aria-labelledby="services-title">
      <div className="page">
        <header className="section-head services__head">
          <SectionMark n={1} label="Services & prices" />
          <h2 id="services-title">
            <Emphasis text={values['services.title']} />
          </h2>
          {values['services.intro'] && <p className="section-intro">{values['services.intro']}</p>}
        </header>

        {services.status === 'loading' && (
          <div className="services__loading" aria-busy="true">
            <p className="sr-only" role="status">
              Loading services…
            </p>
            {[0, 1, 2, 3].map((i) => (
              <span key={i} className="skeleton skeleton--service" aria-hidden="true" />
            ))}
          </div>
        )}

        {services.status === 'error' &&
          (services.error.code === 'NOT_CONFIGURED' ? (
            <p className="quiet-state">Our services and prices will be listed here soon.</p>
          ) : (
            <Notice tone="error" action={{ label: 'Try again', onClick: onRetry }}>
              <p>We couldn't load our services just now.</p>
            </Notice>
          ))}

        {services.status === 'ready' && all.length === 0 && (
          <p className="quiet-state">Our services will be listed here soon. Call or email the studio to book in the meantime.</p>
        )}

        {all.length > 0 && (
          <div className="menu">
            {sized && (
              <div className="sizes">
                <p className="sizes__label" id="sizes-label">
                  Your dog’s size
                </p>
                <div className="sizes__tabs" role="group" aria-labelledby="sizes-label">
                  <button type="button" className="size-tab" aria-pressed={activeSize === null} onClick={() => setSize(null)}>
                    <span className="size-tab__name">All sizes</span>
                    <span className="size-tab__range">Every service</span>
                  </button>
                  {SIZES.map((s) => (
                    <button
                      key={s.id}
                      type="button"
                      className="size-tab"
                      aria-pressed={activeSize === s.id}
                      onClick={() => setSize((current) => (current === s.id ? null : s.id))}
                    >
                      <span className="size-tab__name">{s.label}</span>
                      {values[SIZE_FIELD[s.id]] && <span className="size-tab__range">{values[SIZE_FIELD[s.id]]}</span>}
                    </button>
                  ))}
                </div>
                {values['sizes.note'] && <p className="sizes__note">{values['sizes.note']}</p>}
                <p className="sr-only" role="status" aria-live="polite">
                  {sizeLabel ? `Showing ${shown} ${shown === 1 ? 'service' : 'services'} for ${sizeLabel} dogs.` : ''}
                </p>
              </div>
            )}

            <div className="menu__kinds" data-size={activeSize ?? 'all'}>
              {groups.map((g) => {
                const note = g.note ? values[g.note] : '';
                return (
                  <section className="kind" id={`services-${g.id}`} key={g.id} aria-labelledby={`services-${g.id}-title`}>
                    <div className="kind__head">
                      <h3 className="kind__title" id={`services-${g.id}-title`}>
                        {g.label}
                      </h3>
                      {note && <p className="kind__note">{note}</p>}
                    </div>
                    <ul className="menu-list" role="list">
                      {g.services.map((s) => {
                        const { lead, suits } = splitDescription(s.description);
                        const { base, size: sizeName } = splitName(s.name);
                        const price = priceParts(s, locale);
                        return (
                          <li className="item" key={s.id}>
                            <div className="item__main">
                              {s.image && (
                                <img
                                  className="item__thumb"
                                  src={s.image.url}
                                  alt={s.image.alt}
                                  width={s.image.width ?? 160}
                                  height={s.image.height ?? 160}
                                  loading="lazy"
                                  decoding="async"
                                />
                              )}
                              <h4 className="item__name">
                                {base}
                                {sizeName && (
                                  <>
                                    <span className="sr-only"> — </span>
                                    <span className="item__size">{sizeName}</span>
                                  </>
                                )}
                              </h4>
                              {lead && <p className="item__lead">{lead}</p>}
                              {suits.length > 0 && (
                                <p className="item__for">
                                  <span className="item__for-label">For</span> {suits.join(' · ')}
                                </p>
                              )}
                            </div>
                            <div className="item__end">
                              <p className="item__time">
                                <span aria-hidden="true">{durationLabel(s.durationMinutes)}</span>
                                <span className="sr-only">Booked for {durationSpoken(s.durationMinutes)}</span>
                              </p>
                              <p className="item__price">
                                {price.from && <span className="item__from">from </span>}
                                {price.amount}
                              </p>
                              <a className="button button--small button--quiet item__book" href="#book" onClick={bookLink(onBook, s.id)}>
                                Book<span className="sr-only"> {s.name}</span>
                                <span className="button__arrow" aria-hidden="true">
                                  →
                                </span>
                              </a>
                            </div>
                          </li>
                        );
                      })}
                    </ul>
                  </section>
                );
              })}
            </div>

            {values['services.priceNote'] && (
              <aside className="price-note" aria-label="About prices">
                <span className="price-note__icon" aria-hidden="true">
                  i
                </span>
                <p className="prewrap">{values['services.priceNote']}</p>
              </aside>
            )}
          </div>
        )}
      </div>
    </section>
  );
}
