// booking-mailer — Supabase Edge Function that sends the Booking Engine's emails.
// ENGINE-OWNED FILE (installed by `booking-engine init` / `sync`). Do not edit.
//
// Called by the project's own database, never by the website: pg_net (after
// each queued email) and pg_cron (every minute, for retries and expiry
// notices), with the mailer-only token in the `x-booking-mailer-token` header.
// It takes no input — it can only send what the database already queued.
//
// Deploy:   npx supabase functions deploy booking-mailer --no-verify-jwt
// Secrets:  BOOKING_MAILER_TOKEN, RESEND_API_KEY, BOOKING_EMAIL_FROM (see mailer.js)
//
// Authentication: the platform JWT check is off (`verify_jwt = false`) and the
// function authenticates every call itself — the pattern @supabase/server
// documents for its `none` mode. Only the mailer token is accepted (compared in
// constant time; fails closed when the secret is missing), so the database
// never needs a Supabase secret key. The function's own database access uses
// the project's default secret key, which never leaves the function runtime.
// No browser calls this function, so CORS is disabled.
import { withSupabase } from '@supabase/server'; // exact version pinned in deno.json
import { authorizeMailerRequest, runMailer } from './mailer.js';

export default {
  fetch: withSupabase({ auth: 'none', cors: 'disabled' }, async (req, ctx) => {
    const auth = await authorizeMailerRequest(req, (name: string) => Deno.env.get(name));
    if (!auth.ok) {
      if (auth.status === 503) console.error(JSON.stringify({ event: 'booking-mailer', error: 'BOOKING_MAILER_TOKEN is not set (Edge Function secret)' }));
      return Response.json({ error: auth.error }, { status: auth.status });
    }
    if (req.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'POST' } });
    }
    try {
      const result = await runMailer({
        db: ctx.supabaseAdmin,
        env: (name: string) => Deno.env.get(name),
        log: (entry: object) => console.log(JSON.stringify(entry)),
      });
      return Response.json(result);
    } catch (error) {
      console.error(JSON.stringify({ event: 'booking-mailer', error: String((error as Error)?.message ?? error).slice(0, 300) }));
      return Response.json({ error: 'The mailer could not finish; queued emails are retried.' }, { status: 500 });
    }
  }),
};
