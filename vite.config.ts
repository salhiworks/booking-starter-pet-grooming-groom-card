import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';
import { publishedSiteContent } from '@profitstudio/booking-engine/vite';
import { siteContent } from './src/content/site.ts';

// A multi-page build: the public site (index.html) and the packaged dashboard
// (admin/index.html). The engine's plugin checks the Supabase variables and
// bakes the owner's published content into index.html at build time.
export default defineConfig(({ mode }) => ({
  // The public Live Demo build (`--mode demo`): src/lib/engine.ts swaps in the
  // in-browser demo engine (src/demo/). Every other build leaves it out.
  define: { __BOOKING_DEMO__: JSON.stringify(mode === 'demo') },
  plugins: [
    // …and keeps the demo's sample data out of it too: outside demo mode,
    // src/demo/config resolves to an empty module.
    {
      name: 'booking-demo-config-off',
      enforce: 'pre',
      resolveId: (id) => (mode !== 'demo' && /\/demo\/config(\.ts)?$/.test(id) ? '\0booking-demo-off' : null),
      load: (id) => (id === '\0booking-demo-off' ? 'export const demoConfig = undefined;' : null),
    },
    react(),
    publishedSiteContent({
      schema: siteContent,
      env: loadEnv(mode, process.cwd(), 'VITE_'),
      meta: (values) => ({ title: values['seo.title'], description: values['seo.description'] }),
    }),
  ],
  server: { port: 5179, strictPort: true },
  preview: { port: 5179, strictPort: true },
  build: {
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL('./index.html', import.meta.url)),
        admin: fileURLToPath(new URL('./admin/index.html', import.meta.url)),
      },
    },
  },
}));
