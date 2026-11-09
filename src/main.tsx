import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
// Young Serif (headlines) and Figtree (variable 300–900, everything else). Latin subsets only.
import '@fontsource/young-serif/latin-400.css';
import '@fontsource-variable/figtree/index.css';
import './styles/tokens.css';
import './styles/base.css';
import './styles/site.css';
import './styles/booking.css';
import { App } from './App';
import { engine } from './lib/engine';
import type { DemoEngine } from './demo/engine';

if (__BOOKING_DEMO__) void import('./demo/engine/DemoBar').then((m) => m.mountDemoBar(engine as DemoEngine, 'site'));

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
