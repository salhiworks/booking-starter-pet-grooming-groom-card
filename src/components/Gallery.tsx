import type { CSSProperties } from 'react';
import type { SiteImage } from '@profitstudio/booking-engine';
import type { SiteValues } from '../lib/content';
import { Emphasis } from './Emphasis';
import { Photo } from './Photo';
import { SectionMark } from './SectionMark';

/** The six frames, in two rows of three: each slot keeps its shape (a removed photo closes the gap). */
const SLOTS = [
  { n: 1, shape: 'landscape' },
  { n: 2, shape: 'portrait' },
  { n: 3, shape: 'portrait' },
  { n: 4, shape: 'landscape' },
  { n: 5, shape: 'landscape' },
  { n: 6, shape: 'landscape' },
] as const;

type PhotoKey = `gallery.photo${(typeof SLOTS)[number]['n']}`;
type CaptionKey = `gallery.caption${(typeof SLOTS)[number]['n']}`;

interface Frame {
  n: number;
  shape: 'portrait' | 'landscape';
  photo: SiteImage;
  caption: string;
  sample: boolean;
}

const SIZES = {
  portrait: '(min-width: 720px) 22vw, 50vw',
  landscape: '(min-width: 720px) 40vw, 100vw',
} as const;

/**
 * From the grooming table: six frames of coat work in two justified rows (each
 * row one height, every photo whole in its own shape; two columns on phones), each with a short
 * caption naming the coat and the work. Sample photos say so until the owner
 * replaces them; there are no before-and-after pairs.
 */
export function Gallery({ values, ownerFields }: { values: SiteValues; ownerFields: string[] }) {
  const frames: Frame[] = SLOTS.flatMap(({ n, shape }) => {
    const photo = values[`gallery.photo${n}` as PhotoKey];
    if (!photo) return [];
    return [{ n, shape, photo, caption: values[`gallery.caption${n}` as CaptionKey].trim(), sample: !ownerFields.includes(`gallery.photo${n}`) }];
  });
  if (frames.length === 0) return null;
  const sample = frames.some((f) => f.sample);
  return (
    <section id="gallery" className="section gallery" aria-labelledby="gallery-title">
      <div className="page">
        <header className="section-head gallery__head">
          <SectionMark n={2} label="Gallery" />
          <h2 id="gallery-title">
            <Emphasis text={values['gallery.title']} />
          </h2>
          {values['gallery.intro'] && <p className="section-intro">{values['gallery.intro']}</p>}
          {sample && (
            <p className="sample-note">
              <span className="tag">Sample photos</span>
              Example photography from a grooming studio — not this studio’s clients or its own work.
            </p>
          )}
        </header>
        <div className="gallery__grid" data-count={frames.length}>
          {[frames.slice(0, 3), frames.slice(3)].map((row, r) =>
            row.length === 0 ? null : (
              <ul className="gallery__row" role="list" key={r}>
                {row.map((f) => (
                  <li
                    key={`${f.n}-${f.photo.src}`}
                    className={`gallery__item gallery__item--${f.shape}`}
                    style={{ '--ar': f.shape === 'portrait' ? 0.8 : 1.5 } as CSSProperties}
                  >
                    <figure>
                      <div className="gallery__frame">
                        <Photo image={f.photo} sizes={SIZES[f.shape]} className={`gallery__photo gallery__photo--${f.shape}`} />
                        {f.sample && <span className="tag tag--on-photo">Sample</span>}
                      </div>
                      {f.caption && <figcaption className="gallery__caption">{f.caption}</figcaption>}
                    </figure>
                  </li>
                ))}
              </ul>
            ),
          )}
        </div>
      </div>
    </section>
  );
}
