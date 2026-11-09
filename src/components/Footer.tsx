import type { Business } from '@profitstudio/booking-engine';
import type { StartBooking } from '../App';
import { telHref } from '../lib/contact';
import type { SiteValues } from '../lib/content';
import { bookLink } from '../lib/bookLink';
import { NAV } from '../lib/nav';

const YEAR = new Date().getFullYear();

export function Footer({ values, business, onBook }: { values: SiteValues; business: Business | null; onBook: StartBooking }) {
  const contact = business?.contact;
  return (
    <footer className="site-footer">
      <div className="page site-footer__inner">
        <div className="site-footer__brand">
          {/* The name mark, always: the owner's logo may be drawn for another background. */}
          <p className="site-footer__name">
            <span className="wordmark__tag wordmark__tag--footer" aria-hidden="true" />
            {values['brand.wordmark']}
          </p>
          {values['footer.tagline'] && <p className="site-footer__tagline">{values['footer.tagline']}</p>}
          <a className="button" href="#book" onClick={bookLink(onBook)}>
            {values['hero.cta']}
          </a>
        </div>
        <nav className="site-footer__col" aria-label="Footer">
          <p className="site-footer__label">On this page</p>
          <ul role="list">
            {NAV.map((item) => (
              <li key={item.href}>
                <a href={item.href}>{item.label}</a>
              </li>
            ))}
          </ul>
        </nav>
        {contact && (contact.address || contact.phone || contact.email) && (
          <div className="site-footer__col">
            <p className="site-footer__label">Contact</p>
            <address className="site-footer__contact">
              {contact.address && <span className="prewrap">{contact.address}</span>}
              {contact.phone && <a href={telHref(contact.phone)}>{contact.phone}</a>}
              {contact.email && <a href={`mailto:${contact.email}`}>{contact.email}</a>}
            </address>
          </div>
        )}
      </div>
      <div className="page site-footer__meta">
        <p>
          © {YEAR} {business?.name ?? values['brand.wordmark']}
        </p>
        <a className="site-footer__staff" href="/admin/">
          Staff login
        </a>
      </div>
    </footer>
  );
}
