import type { ContentState } from '../lib/content';

/** Preview mode (no backend, development only): always visible. */
export function PreviewBanner() {
  return (
    <div className="banner banner--preview">
      <p>
        <span className="banner__dot" aria-hidden="true" />
        Preview — sample data, bookings are not saved
      </p>
    </div>
  );
}

/** ?preview=draft from the dashboard's Website editor. */
export function DraftBanner({ content }: { content: ContentState }) {
  if (content.preview) {
    return (
      <div className="banner banner--draft" role="status">
        <p>You are previewing an unpublished draft. Visitors still see the published website.</p>
      </div>
    );
  }
  if (content.previewDenied) {
    return (
      <div className="banner banner--draft" role="status">
        <p>Draft previews are only shown to staff signed in to the dashboard in this browser. This is the published website.</p>
      </div>
    );
  }
  return null;
}
