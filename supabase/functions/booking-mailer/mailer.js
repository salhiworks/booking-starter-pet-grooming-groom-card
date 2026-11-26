// booking-mailer — sends the Booking Engine's queued emails.
// ENGINE-OWNED FILE (installed by `booking-engine init` / `sync`). Do not edit.
//
// Runtime-neutral core (Supabase Edge Functions / Deno, and Node for tests).
// One run: lease due emails from the database (booking_mailer_claim), render
// each from its stored payload, send it through the provider with the outbox
// id as idempotency key, and report the result (booking_mailer_report). The
// database decides what is sent, to whom and when; this code only delivers.
// Nothing here logs addresses, names, codes or keys.
//
// Function secrets:
//   BOOKING_MAILER_TOKEN    the mailer-only token from `select * from booking.configure_mailer(…)`
//                           (the database sends it as x-booking-mailer-token; nothing else is accepted)
//   RESEND_API_KEY          provider key (server only)
//   BOOKING_EMAIL_FROM      sender on a verified domain, e.g. "Copper & Comb <bookings@mail.example.com>"
//                           (an address alone uses the business name as display name). Resend's
//                           testing address (onboarding@resend.dev) is refused: see TESTING_SENDER.
//   BOOKING_EMAIL_PROVIDER  optional, default "resend"
//   BOOKING_ADMIN_URL       optional dashboard link in owner alerts (https)
import { providerFromEnv } from './providers/index.js';
import { REVISION } from './revision.js';
import { renderEmail } from './templates.js';

const BATCH_SIZE = 10;
const MAX_BATCHES = 5;
const SEND_GAP_MS = 120; // stays below Resend's default of 10 requests per second
// Each leased email carries its lease (leaseSeconds, 2.0.0-beta.5). An email is
// not sent once its lease is about to end: by then the database may give it to
// another mailer, or withdraw it. A send takes at most 15 s, a report 10 s.
const LEASE_MARGIN_MS = 30_000;
const DEFAULT_LEASE_SECONDS = 120; // a database older than 2.0.0-beta.5
const RPC_TIMEOUT_MS = 10_000;

const ADDRESS = /^[^@\s<>"]+@[^@\s<>"]+\.[^@\s<>"]{2,}$/;
const TOKEN_HEADER = 'x-booking-mailer-token';

// Resend's shared testing domain delivers only to the address of the Resend
// account itself: the owner's test email arrives, then every customer's code is
// refused (403). A test that passes proves nothing here, so the mailer refuses
// it as a sender and tells the owner what to do instead. (Local development
// uses the fake Resend of the test stack; a public demo sends nothing.)
const TESTING_SENDER = /@(?:[^@\s]+\.)?resend\.dev$/i;
const TESTING_SENDER_ERROR =
  "BOOKING_EMAIL_FROM uses Resend's testing address (@resend.dev), which delivers only to your own Resend account address: " +
  'customers would never receive their codes. Verify your domain in Resend and use an address on it, e.g. "Your Business <bookings@mail.yourdomain.com>".';

/**
 * The only credential the mailer accepts: the mailer token the database holds
 * (booking.mailer_config), compared in constant time. Fails closed when the
 * secret is missing. A Supabase key — publishable or secret — is NOT accepted:
 * starting the mailer needs no more than this narrow token.
 * @param {Request} request
 * @param {(name: string) => string | undefined} env
 * @returns {Promise<{ ok: true } | { ok: false, status: 401 | 503, error: string }>}
 */
export async function authorizeMailerRequest(request, env) {
  const expected = (env('BOOKING_MAILER_TOKEN') || '').trim();
  if (expected.length < 32) return { ok: false, status: 503, error: 'Mailer not configured' };
  const given = request.headers.get(TOKEN_HEADER) ?? '';
  return (await sameSecret(given, expected)) ? { ok: true } : { ok: false, status: 401, error: 'Unauthorized' };
}

async function sameSecret(a, b) {
  const encoder = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(a)),
    crypto.subtle.digest('SHA-256', encoder.encode(b)),
  ]);
  const u = new Uint8Array(x);
  const v = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < u.length; i++) diff |= u[i] ^ v[i];
  return diff === 0;
}

/**
 * @param {object} options
 * @param {{ rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: any, error: any }> }} options.db
 *   A Supabase client with the secret key (service_role).
 * @param {(name: string) => string | undefined} options.env
 * @param {typeof fetch} [options.fetch]
 * @param {(ms: number) => Promise<void>} [options.sleep]
 * @param {(entry: object) => void} [options.log]
 */
export async function runMailer({ db, env, fetch: fetchImpl = globalThis.fetch, sleep = defaultSleep, log = () => {} }) {
  await reportRevision(db);
  const from = parseFrom(env('BOOKING_EMAIL_FROM'));
  const selected = providerFromEnv(env, fetchImpl);
  const problem = selected.error ?? from.error;
  if (problem) {
    await call(db, 'booking_mailer_report_unconfigured', { p_error: problem });
    log({ event: 'booking-mailer', configured: false });
    return { configured: false, error: problem };
  }
  const { provider } = selected;
  const adminUrl = env('BOOKING_ADMIN_URL') || undefined;
  const totals = { sent: 0, retrying: 0, failed: 0 };
  let deferred = 0;

  // Claim until nothing is due: an email held back while an older one of its
  // booking was being sent (by this run) goes out in the same run.
  run: for (let batch = 0; batch < MAX_BATCHES; batch++) {
    const claimedAt = Date.now();
    const claimed = (await call(db, 'booking_mailer_claim', { p_limit: BATCH_SIZE })) ?? [];
    if (!claimed.length) break;
    for (const [index, mail] of claimed.entries()) {
      const lease = (Number(mail.leaseSeconds) || DEFAULT_LEASE_SECONDS) * 1000;
      if (Date.now() - claimedAt > lease - LEASE_MARGIN_MS) {
        // Too slow to send it inside its lease: it (and the rest) is retried after the lease.
        deferred = claimed.length - index;
        break run;
      }
      const result = await deliver(provider, mail, { from, adminUrl });
      await call(db, 'booking_mailer_report', {
        p_id: mail.id,
        p_attempt: mail.attempt,
        p_ok: result.ok,
        p_provider_id: result.ok ? result.id : null,
        p_error: result.ok ? null : result.error,
        p_permanent: result.ok ? false : result.permanent,
      });
      if (result.ok) totals.sent++;
      else if (result.permanent || mail.attempt >= 5) totals.failed++;
      else totals.retrying++;
      await sleep(SEND_GAP_MS);
    }
  }
  log({ event: 'booking-mailer', configured: true, provider: provider.name, ...totals, ...(deferred ? { deferred } : {}) });
  return { configured: true, ...totals };
}

async function deliver(provider, mail, { from, adminUrl }) {
  let email;
  try {
    email = renderEmail(mail, { adminUrl });
  } catch (error) {
    return { ok: false, permanent: true, error: `Could not render the email: ${String(error?.message ?? error).slice(0, 200)}` };
  }
  if (!ADDRESS.test(mail.to ?? '')) return { ok: false, permanent: true, error: 'Invalid recipient address.' };
  try {
    return await provider.send({
      idempotencyKey: `booking-engine-${mail.id}`,
      from: from.address ? sender(from, mail.payload?.businessName) : from.full,
      to: mail.to,
      replyTo: email.replyTo && ADDRESS.test(email.replyTo) ? email.replyTo : undefined,
      subject: email.subject,
      html: email.html,
      text: email.text,
    });
  } catch (error) {
    return { ok: false, permanent: false, error: `Provider error: ${String(error?.message ?? error).slice(0, 200)}` };
  }
}

/**
 * BOOKING_EMAIL_FROM: "Name <address>" (used as is) or an address (named after the business).
 * Resend's testing address is refused (TESTING_SENDER).
 */
export function parseFrom(value) {
  const v = (value ?? '').trim();
  if (!v) return { error: 'BOOKING_EMAIL_FROM is not set (Edge Function secret), e.g. "Your Business <bookings@mail.yourdomain.com>".' };
  const named = /^(.*)<([^<>]+)>$/.exec(v);
  if (named) {
    const address = named[2].trim();
    if (!ADDRESS.test(address)) return { error: 'BOOKING_EMAIL_FROM does not contain a valid email address.' };
    if (TESTING_SENDER.test(address)) return { error: TESTING_SENDER_ERROR };
    return { full: `${quoteName(named[1])} <${address}>`.trim() };
  }
  if (!ADDRESS.test(v)) return { error: 'BOOKING_EMAIL_FROM is not a valid email address.' };
  if (TESTING_SENDER.test(v)) return { error: TESTING_SENDER_ERROR };
  return { address: v };
}

function sender(from, businessName) {
  const name = quoteName(businessName ?? '');
  return name ? `${name} <${from.address}>` : from.address;
}

function quoteName(name) {
  const n = String(name).replace(/["\\<>\r\n\t]/g, '').replace(/\s+/g, ' ').trim().slice(0, 70);
  return n ? `"${n}"` : '';
}

/**
 * Tell the database which mailer code is deployed (its REVISION, a digest of these files), so the
 * dashboard can say whether it matches the website's engine. Never stops a run: a database from
 * before migration 0012 has no booking_mailer_hello, and then there is simply nothing recorded.
 */
async function reportRevision(db) {
  try {
    await call(db, 'booking_mailer_hello', { p_revision: REVISION });
  } catch {
    // Older database, or a hiccup: sending goes on; the next run reports again.
  }
}

async function call(db, fn, args) {
  let query = db.rpc(fn, args);
  // A database call never hangs the run (supabase-js queries take an abort signal).
  if (typeof query?.abortSignal === 'function') query = query.abortSignal(AbortSignal.timeout(RPC_TIMEOUT_MS));
  const { data, error } = await query;
  if (error) throw new Error(`${fn} failed: ${error.message ?? error}`);
  return data;
}

const defaultSleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
