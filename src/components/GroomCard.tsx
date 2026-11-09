import type { SiteValues } from '../lib/content';

/**
 * The groom card: the record a groomer keeps for every dog (coat, clip length,
 * likes and dislikes, when the coat is due again), drawn as a cream index card
 * with a punched hole and ruled lines. It describes the studio's practice —
 * the groomer keeps it, not the website, and it shows no real dog's details.
 */
export function GroomCard({ values, className }: { values: SiteValues; className?: string }) {
  const title = values['hero.cardTitle'].trim();
  const items = values['hero.cardItems'];
  const note = values['hero.cardNote'].trim();
  if (!title) return null;
  return (
    <aside className={`groom-card ${className ?? ''}`} aria-label={title}>
      <span className="groom-card__hole" aria-hidden="true" />
      <p className="groom-card__label" aria-hidden="true">
        Groom card
      </p>
      <p className="groom-card__title">{title}</p>
      {items.length > 0 && (
        <ul className="groom-card__lines" role="list">
          {items.map((item, i) => (
            <li key={`${i}-${item.text}`}>
              <span>{item.text}</span>
            </li>
          ))}
        </ul>
      )}
      {note && <p className="groom-card__note">{note}</p>}
    </aside>
  );
}
