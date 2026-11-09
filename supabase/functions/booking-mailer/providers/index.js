// booking-mailer — the email provider boundary.
// ENGINE-OWNED FILE (installed by `booking-engine init` / `sync`). Do not edit.
//
// A provider is one object with one method. Everything else — what to send,
// when, to whom, retries, de-duplication, the booking rules — stays in the
// engine. Adding a provider means adding a factory here; nothing else changes.
//
// @typedef {object} OutgoingEmail
// @property {string} idempotencyKey  Stable per queued email: a retry is never a second email.
// @property {string} from            "Display Name <address@domain>"
// @property {string} to
// @property {string} [replyTo]
// @property {string} subject
// @property {string} html
// @property {string} text
//
// @typedef {{ ok: true, id: string } | { ok: false, permanent: boolean, error: string }} SendResult
//   permanent: retrying the same email cannot succeed (bad address, rejected content).
//   error: a short, human-readable reason shown to the owner. Never include secrets.
//
// @typedef {object} EmailProvider
// @property {string} name
// @property {(email: OutgoingEmail) => Promise<SendResult>} send
import { createResendProvider } from './resend.js';

/** Provider factories by name: (env, fetch) → { provider } | { error }. */
export const PROVIDERS = {
  resend: createResendProvider,
};

/**
 * The provider the function secrets select (BOOKING_EMAIL_PROVIDER, default "resend").
 * @param {(name: string) => string | undefined} env
 * @param {typeof fetch} fetchImpl
 * @returns {{ provider: EmailProvider } | { error: string }}
 */
export function providerFromEnv(env, fetchImpl) {
  const name = (env('BOOKING_EMAIL_PROVIDER') || 'resend').trim().toLowerCase();
  const factory = PROVIDERS[name];
  if (!factory) return { error: `Unknown BOOKING_EMAIL_PROVIDER "${name}". Supported: ${Object.keys(PROVIDERS).join(', ')}.` };
  return factory(env, fetchImpl);
}
