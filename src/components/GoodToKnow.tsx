import type { SiteValues } from '../lib/content';
import { Emphasis } from './Emphasis';
import { SectionMark } from './SectionMark';

/**
 * The practical questions before a first groom, as native disclosure rows (keyboard and screen-reader ready).
 * Until the owner edits them, they are labelled as sample policies.
 */
export function GoodToKnow({ values, ownerFields }: { values: SiteValues; ownerFields: string[] }) {
  const items = values['faq.items'];
  if (items.length === 0) return null;
  return (
    <section id="good-to-know" className="section faq" aria-labelledby="faq-title">
      <div className="page faq__grid">
        <header className="section-head faq__head">
          <SectionMark n={5} label="Good to know" />
          <h2 id="faq-title">
            <Emphasis text={values['faq.title']} />
          </h2>
          {!ownerFields.includes('faq.items') && (
            <p className="sample-note">
              <span className="tag">Sample policies</span>
              Example answers the studio edits in its dashboard — check the details with the studio.
            </p>
          )}
        </header>
        <div className="faq__list">
          {items.map((item, i) => (
            <details className="qa" key={`${i}-${item.question}`} open={i === 0}>
              <summary>
                <span className="qa__q">{item.question}</span>
                <span className="qa__icon" aria-hidden="true" />
              </summary>
              {item.answer && <p className="qa__a prewrap">{item.answer}</p>}
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
