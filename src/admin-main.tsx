import { createRoot } from 'react-dom/client';
import { BookingAdmin } from '@profitstudio/booking-engine/admin';
import '@profitstudio/booking-engine/admin.css';
import './admin-theme.css';
import { engine } from './lib/engine';
import type { DemoEngine } from './demo/engine';
import { siteContent } from './content/site';
import { sitePreset } from './lib/preset';

// The Live Demo sends no email, so its dashboard must never say a customer gets one
// (emailDelivery, engine 2.0.0-beta.2). A real build passes nothing: live texts.
if (__BOOKING_DEMO__) void import('./demo/engine/DemoBar').then((m) => m.mountDemoBar(engine as DemoEngine, 'admin'));

createRoot(document.getElementById('admin')!).render(
  <BookingAdmin engine={engine} siteUrl="/" content={siteContent} presets={[sitePreset]} emailDelivery={__BOOKING_DEMO__ ? 'none' : undefined} />,
);
