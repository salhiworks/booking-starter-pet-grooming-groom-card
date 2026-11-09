// VENDORED from booking-niche-packs/shared/demo-engine — edit it there, then run scripts/sync-shared.mjs.
import { createRoot } from 'react-dom/client';
import type { DemoEngine } from './createDemoEngine';
import { DemoDock } from './DemoDock';

// The Live Demo dock — see DemoDock.tsx. Every starter imports this file (and only
// in a demo build): `mountDemoBar(engine, 'site' | 'admin')`.

/** Put the dock on the page, outside the app's own root (fixed, so it takes no space). */
export function mountDemoDock(engine: DemoEngine, page: 'site' | 'admin'): void {
  if (typeof document === 'undefined' || document.getElementById('booking-demo-bar')) return;
  const host = document.createElement('div');
  host.id = 'booking-demo-bar';
  document.body.append(host);
  createRoot(host).render(<DemoDock engine={engine} page={page} host={host} />);
}

/** The name every starter already calls (kept so no starter has to change). */
export const mountDemoBar = mountDemoDock;

