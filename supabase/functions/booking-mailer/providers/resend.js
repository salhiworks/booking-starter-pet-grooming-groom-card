// booking-mailer — Resend (https://resend.com) through its HTTP API.
// ENGINE-OWNED FILE (installed by `booking-engine init` / `sync`). Do not edit.
//
// Function secrets: RESEND_API_KEY (required; a "Sending access" key is enough).
// RESEND_API_URL is for local tests only (a fake Resend server).
//
// Resend keeps an Idempotency-Key for 24 hours: the same key with the same
// content returns the first result without sending again; the same key with
// different content is refused (409). The outbox id is the key, and emails are
// rendered from the stored payload only, so a retry is always identical.

const DEFAULT_API_URL = 'https://api.resend.com';
const TIMEOUT_MS = 15_000;
// Retrying cannot fix these: the request itself is wrong.
const PERMANENT_STATUS = new Set([400, 404, 405, 413, 422]);

/**
 * @param {(name: string) => string | undefined} env
 * @param {typeof fetch} fetchImpl
 */
export function createResendProvider(env, fetchImpl) {
  const apiKey = (env('RESEND_API_KEY') || '').trim();
  if (!apiKey) return { error: 'RESEND_API_KEY is not set (Edge Function secret).' };
  const base = (env('RESEND_API_URL') || DEFAULT_API_URL).trim().replace(/\/+$/, '');
  return {
    provider: {
      name: 'resend',
      send: (email) => send({ apiKey, base, fetchImpl }, email),
    },
  };
}

async function send({ apiKey, base, fetchImpl }, email) {
  let response;
  try {
    response = await fetchImpl(`${base}/emails`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': email.idempotencyKey,
        'User-Agent': 'profitstudio-booking-engine',
      },
      body: JSON.stringify({
        from: email.from,
        to: [email.to],
        subject: email.subject,
        html: email.html,
        text: email.text,
        ...(email.replyTo ? { reply_to: email.replyTo } : {}),
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (error) {
    const reason = error?.name === 'TimeoutError' ? 'timed out' : 'network error';
    return { ok: false, permanent: false, error: `Resend could not be reached (${reason}).` };
  }

  let body = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  if (response.ok && body && typeof body.id === 'string') return { ok: true, id: body.id };

  const name = typeof body?.name === 'string' ? body.name : 'error';
  const message = typeof body?.message === 'string' ? body.message : '';
  const permanent = PERMANENT_STATUS.has(response.status) || name === 'invalid_idempotent_request';
  return {
    ok: false,
    permanent,
    error: `Resend ${response.status} ${name}${message ? `: ${message}` : ''}`.slice(0, 300),
  };
}
