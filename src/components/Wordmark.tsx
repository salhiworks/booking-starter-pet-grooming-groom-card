import type { SiteValues } from '../lib/content';

/** The owner's logo when set, otherwise the name mark: the name in the serif, a small groom-card tag, and the descriptor under it. */
export function Wordmark({ values, className }: { values: SiteValues; className?: string }) {
  const logo = values['brand.logo'];
  const name = values['brand.wordmark'];
  const descriptor = values['brand.descriptor'].trim();
  return (
    <span className={`wordmark ${className ?? ''}`}>
      {logo ? (
        <img
          className="wordmark__logo"
          src={logo.src}
          alt={logo.alt || name}
          width={logo.width ?? 160}
          height={logo.height ?? 40}
          decoding="async"
        />
      ) : (
        <>
          <span className="wordmark__tag" aria-hidden="true" />
          <span className="wordmark__words">
            <span className="wordmark__text">{name}</span>
            {descriptor && <span className="wordmark__descriptor">{descriptor}</span>}
          </span>
        </>
      )}
    </span>
  );
}
