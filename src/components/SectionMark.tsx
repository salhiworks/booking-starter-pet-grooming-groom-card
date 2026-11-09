/**
 * A section's label, written like the tab of an index card: its number and
 * name in small capitals. Decorative — hidden from screen readers; the heading
 * below names the section.
 */
export function SectionMark({ n, label, tone }: { n: number; label: string; tone?: 'on-accent' }) {
  return (
    <p className={`section-mark ${tone ? `section-mark--${tone}` : ''}`} aria-hidden="true">
      <span className="section-mark__n">{String(n).padStart(2, '0')}</span>
      <span className="section-mark__label">{label}</span>
    </p>
  );
}
