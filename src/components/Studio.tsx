import type { SiteValues } from '../lib/content';
import { engine } from '../lib/engine';
import { Emphasis } from './Emphasis';
import { Photo } from './Photo';
import { SectionMark } from './SectionMark';

/** The Live Demo and preview mode show a fictional studio: say so beside it. */
const SAMPLE_BUSINESS = __BOOKING_DEMO__ || engine.mode === 'preview';

/**
 * The studio: the room in one wide frame with an upright detail of the tools
 * overlapping its corner, who the studio is in a few paragraphs, and how it
 * works as a short list of plain care standards. No named groomer, no awards or
 * certificates: the studio speaks as "we" (the owner adds names and real
 * qualifications themselves).
 */
export function Studio({ values, ownerFields }: { values: SiteValues; ownerFields: string[] }) {
  const room = values['studio.photoRoom'];
  const detail = values['studio.photoDetail'];
  const facts = values['studio.facts'];
  const paragraphs = values['studio.text'].split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  const sample = (id: string) => !ownerFields.includes(id);
  return (
    <section id="studio" className="section studio" aria-labelledby="studio-title">
      <div className="page studio__grid">
        <header className="section-head studio__head">
          <SectionMark n={4} label="The studio" />
          <h2 id="studio-title">
            <Emphasis text={values['studio.title']} />
          </h2>
        </header>
        {(room || detail) && (
          <div className={`studio__photos ${room && detail ? '' : 'studio__photos--single'}`}>
            {room && (
              <figure className="studio__room">
                <Photo image={room} sizes="(min-width: 1024px) 46vw, 100vw" className="studio__photo studio__photo--room" />
                {sample('studio.photoRoom') && <span className="tag tag--on-photo">Sample</span>}
              </figure>
            )}
            {detail && (
              <figure className="studio__detail">
                <Photo image={detail} sizes="(min-width: 1024px) 16vw, 40vw" className="studio__photo studio__photo--detail" />
                {sample('studio.photoDetail') && <span className="tag tag--on-photo">Sample</span>}
              </figure>
            )}
          </div>
        )}
        <div className="studio__text">
          {paragraphs.map((p, i) => (
            <p key={i} className={i === 0 ? 'studio__lead prewrap' : 'prewrap'}>
              {p}
            </p>
          ))}
          {SAMPLE_BUSINESS && (
            <p className="sample-note">
              <span className="tag">Sample</span>
              {__BOOKING_DEMO__ ? 'This demo shows a fictional studio' : 'Preview shows a fictional studio'}: the room, the dogs and the photographs are
              licensed stock images from another grooming studio — not its own groomers, clients or space.
            </p>
          )}
        </div>
        {facts.length > 0 && (
          <dl className="studio__facts">
            {facts.map((fact, i) => (
              <div key={`${i}-${fact.title}`}>
                <dt>{fact.title}</dt>
                {fact.text && <dd>{fact.text}</dd>}
              </div>
            ))}
          </dl>
        )}
      </div>
    </section>
  );
}
