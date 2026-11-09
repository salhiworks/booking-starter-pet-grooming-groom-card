import { useEffect, useLayoutEffect, useState } from 'react';
import { createSiteContentStore, readSiteContentSnapshot } from '@profitstudio/booking-engine';
import type { SiteContentState } from '@profitstudio/booking-engine';
import { siteContent } from '../content/site';
import { engine } from './engine';

/** The owner's published content (or a draft for a signed-in admin with ?preview=draft). */
export const contentStore = createSiteContentStore(engine, siteContent, { snapshot: readSiteContentSnapshot() });

export type ContentState = SiteContentState<typeof siteContent>;
export type SiteValues = ContentState['values'];

/** Resolved site content: the snapshot/cache/defaults first, then the current published copy. */
export function useSiteContent(): ContentState {
  const [state, setState] = useState<ContentState>(() => contentStore.initial());

  useEffect(() => {
    let alive = true;
    void contentStore.load().then((next) => {
      if (alive) setState(next);
    });
    return () => {
      alive = false;
    };
  }, []);

  // Brand values map onto the design's own CSS variables before paint, so a
  // returning visitor never sees the old colours flash.
  const accent = state.values['brand.accent'];
  const headings = state.values['brand.headings'];
  const title = state.values['seo.title'];
  const description = state.values['seo.description'];
  useLayoutEffect(() => {
    const root = document.documentElement;
    root.style.setProperty('--accent', accent);
    root.dataset.headings = headings;
    document.title = title;
    document.querySelector('meta[name="description"]')?.setAttribute('content', description);
  }, [accent, headings, title, description]);

  return state;
}
