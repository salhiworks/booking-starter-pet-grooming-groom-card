import type { Business } from '@profitstudio/booking-engine';
import { telHref } from '../../lib/contact';

interface ContactInsteadProps {
  business: Business | null;
  title: string;
  text: string;
}

/** Shown instead of the booking flow when online booking is off or unavailable. */
export function ContactInstead({ business, title, text }: ContactInsteadProps) {
  const phone = business?.contact.phone;
  const email = business?.contact.email;
  return (
    <div className="contact-instead">
      <h3 className="contact-instead__title">{title}</h3>
      <p>{text}</p>
      {(phone || email) && (
        <ul className="contact-instead__list" role="list">
          {phone && (
            <li>
              <a className="button" href={telHref(phone)}>
                Call {phone}
              </a>
            </li>
          )}
          {email && (
            <li>
              <a className="button button--quiet" href={`mailto:${email}`}>
                Email {email}
              </a>
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
