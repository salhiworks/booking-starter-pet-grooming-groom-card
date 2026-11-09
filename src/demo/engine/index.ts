// VENDORED from booking-niche-packs/shared/demo-engine — edit it there, then run scripts/sync-shared.mjs.
// The Booking Live Demo runtime — shared by every Niche Pack starter.
// CANONICAL COPY: booking-niche-packs/shared/demo-engine. Each starter vendors it
// under src/demo/engine/ (scripts/sync-shared.mjs); edit it here, never there.
export { createDemoEngine } from './createDemoEngine';
export type { DemoEngine } from './createDemoEngine';
export type { DemoConfig, DemoCustomer, DemoServicePhoto } from './state';
// The demo dock (the floating "Live demo · Dashboard · ···" capsule) is imported
// on its own (./DemoBar → mountDemoBar / mountDemoDock), and only by a demo build:
// it carries CSS, which a normal build must never pull in through this file.
