import type { SiteValues } from '../lib/content';
import { Emphasis } from './Emphasis';
import { Photo } from './Photo';
import { SectionMark } from './SectionMark';

const STEPS = [1, 2, 3, 4] as const;
type N = (typeof STEPS)[number];
const key = <S extends string>(n: N, suffix: S) => `experience.step${n}${suffix}` as `experience.step${N}${S}`;

/**
 * A groom, start to finish: drop-off and the coat check, the bath and dry, the
 * trim and finish, collection with aftercare advice — four steps along one lead
 * line, each with its photo, the moment it happens and what we do. Desktop: four
 * columns; phones: a column with the photo beside each step.
 */
export function Experience({ values, ownerFields }: { values: SiteValues; ownerFields: string[] }) {
  const steps = STEPS.map((n) => ({
    n,
    when: values[key(n, 'When')].trim(),
    title: values[key(n, 'Title')],
    text: values[key(n, 'Text')],
    photo: values[key(n, 'Photo')],
    sample: !ownerFields.includes(key(n, 'Photo')),
  }));
  return (
    <section id="groom" className="section band experience" aria-labelledby="groom-title">
      <div className="page">
        <header className="section-head experience__head">
          <SectionMark n={3} label="A groom" />
          <h2 id="groom-title">
            <Emphasis text={values['experience.title']} />
          </h2>
          {values['experience.intro'] && <p className="section-intro">{values['experience.intro']}</p>}
        </header>
        <ol className="steps" role="list">
          {steps.map((s) => (
            <li className={`step ${s.photo ? '' : 'step--no-photo'}`} key={s.n}>
              {s.photo && (
                <figure className="step__visual">
                  <Photo image={s.photo} sizes="(min-width: 1024px) 22vw, (min-width: 720px) 30vw, 38vw" className="step__photo" />
                  {s.sample && <span className="tag tag--on-photo">Sample</span>}
                </figure>
              )}
              <div className="step__text">
                <p className="step__when">
                  <span className="step__n" aria-hidden="true">
                    {s.n}
                  </span>
                  {s.when}
                </p>
                <h3 className="step__title">{s.title}</h3>
                {s.text && <p className="step__body prewrap">{s.text}</p>}
              </div>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
