// booking-mailer — the essential booking emails (plain text + simple HTML).
// ENGINE-OWNED FILE (installed by `booking-engine init` / `sync`). Do not edit.
//
// Rendering is a pure function of the queued payload: a retried email is
// byte-identical to the first attempt (required by idempotent delivery).
// Dates use the business time zone and locale; wording is English.

/**
 * @param {{ kind: string, payload: Record<string, any> }} mail
 * @param {{ adminUrl?: string }} [options]
 * @returns {{ subject: string, text: string, html: string, replyTo?: string }}
 */
export function renderEmail(mail, options = {}) {
  const p = mail.payload ?? {};
  const render = KINDS[mail.kind];
  if (!render) throw new Error(`Unknown email kind "${mail.kind}"`);
  const business = clean(p.businessName) || 'Our team';
  const view = render(p, { business, adminUrl: options.adminUrl });
  const contact = [clean(p.address), clean(p.businessPhone), clean(p.businessEmail)].filter(Boolean);
  return {
    subject: oneLine(view.subject),
    text: [view.text.join('\n\n'), contact.length ? `—\n${business}\n${contact.join('\n')}` : `—\n${business}`].join('\n\n') + '\n',
    html: layout({ business, preheader: view.preheader, blocks: view.html, contact }),
    replyTo: view.replyTo ?? (clean(p.businessEmail) || undefined),
  };
}

// ------------------------------------------------------------- the emails --

const KINDS = {
  verification_code(p, { business }) {
    const code = String(p.code ?? '');
    const when = formatWhen(p.startsAt, p);
    const minutes = Number(p.minutesValid) || 15;
    return {
      subject: `${code} is your booking code for ${business}`,
      preheader: `Enter it to send your request for ${clean(p.serviceName)}.`,
      text: [
        `Your booking code for ${business}:`,
        `    ${code}`,
        `Enter it on the booking page to send your request for ${clean(p.serviceName)} on ${when}.`,
        `The code works for ${minutes} minutes, and the time is held for you until then.`,
        `Didn't ask for this? Ignore this email. Nothing is booked without the code.`,
      ],
      html: [
        para(`Your booking code for ${esc(business)}:`),
        codeBox(code),
        para(`Enter it on the booking page to send your request for <strong>${esc(clean(p.serviceName))}</strong> on ${esc(when)}.`),
        para(`The code works for ${minutes} minutes, and the time is held for you until then.`),
        muted(`Didn’t ask for this? Ignore this email. Nothing is booked without the code.`),
      ],
    };
  },

  request_received(p, { business }) {
    const by = p.holdExpiresAt ? ` by ${formatWhen(p.holdExpiresAt, p)}` : '';
    return {
      subject: `Request received: ${clean(p.serviceName)}, ${formatShort(p.startsAt, p)}`,
      preheader: `Not confirmed yet. ${business} will reply${by}.`,
      text: [
        greeting(p),
        `${business} has received your booking request. It is NOT confirmed yet.`,
        detailsText(p),
        `${business} will confirm or decline it${by}. You will get another email either way.`,
      ],
      html: [
        para(esc(greeting(p))),
        para(`${esc(business)} has received your booking request. <strong>It is not confirmed yet.</strong>`),
        detailsHtml(p),
        para(`${esc(business)} will confirm or decline it${esc(by)}. You will get another email either way.`),
      ],
    };
  },

  booking_confirmed(p, { business }) {
    return {
      subject: `Confirmed: ${clean(p.serviceName)}, ${formatShort(p.startsAt, p)}`,
      preheader: `Your appointment with ${business} is confirmed.`,
      text: [
        greeting(p),
        `Your appointment with ${business} is confirmed.`,
        detailsText(p),
        `Need to change or cancel it? ${reach(p, business)}.`,
      ],
      html: [
        para(esc(greeting(p))),
        para(`<strong>Your appointment with ${esc(business)} is confirmed.</strong>`),
        detailsHtml(p),
        para(`Need to change or cancel it? ${esc(reach(p, business))}.`),
      ],
    };
  },

  booking_declined(p, { business }) {
    return {
      subject: `Not available: your request for ${formatShort(p.startsAt, p)}`,
      preheader: `${business} could not accept this request. Nothing is booked.`,
      text: [
        greeting(p),
        `Sorry, ${business} could not accept your request for ${clean(p.serviceName)} on ${formatWhen(p.startsAt, p)}. Nothing is booked.`,
        `You are welcome to choose another time on the website${orReach(p, business)}.`,
      ],
      html: [
        para(esc(greeting(p))),
        para(`Sorry, ${esc(business)} could not accept your request for <strong>${esc(clean(p.serviceName))}</strong> on ${esc(formatWhen(p.startsAt, p))}. Nothing is booked.`),
        para(`You are welcome to choose another time on the website${esc(orReach(p, business))}.`),
      ],
    };
  },

  booking_cancelled(p, { business }) {
    return {
      subject: `Cancelled: ${clean(p.serviceName)}, ${formatShort(p.startsAt, p)}`,
      preheader: `${business} cancelled this appointment.`,
      text: [
        greeting(p),
        `${business} has cancelled your appointment for ${clean(p.serviceName)} on ${formatWhen(p.startsAt, p)} (reference ${clean(p.reference)}).`,
        `If this is unexpected, ${lower(reach(p, business))}.`,
      ],
      html: [
        para(esc(greeting(p))),
        para(`${esc(business)} has cancelled your appointment for <strong>${esc(clean(p.serviceName))}</strong> on ${esc(formatWhen(p.startsAt, p))} (reference ${esc(clean(p.reference))}).`),
        para(`If this is unexpected, ${esc(lower(reach(p, business)))}.`),
      ],
    };
  },

  request_expired(p, { business }) {
    return {
      subject: `Your request for ${formatShort(p.startsAt, p)} has expired`,
      preheader: `It was not confirmed in time. Nothing is booked.`,
      text: [
        greeting(p),
        `Your request for ${clean(p.serviceName)} on ${formatWhen(p.startsAt, p)} was not confirmed in time, so it has expired. Nothing is booked.`,
        `The time may still be free: you can book again on the website${orReach(p, business)}.`,
      ],
      html: [
        para(esc(greeting(p))),
        para(`Your request for <strong>${esc(clean(p.serviceName))}</strong> on ${esc(formatWhen(p.startsAt, p))} was not confirmed in time, so it has expired. Nothing is booked.`),
        para(`The time may still be free: you can book again on the website${esc(orReach(p, business))}.`),
      ],
    };
  },

  owner_new_request(p, { adminUrl }) {
    const name = clean(p.customerName) || 'A customer';
    const confirmed = p.status === 'confirmed';
    const by = p.holdExpiresAt ? ` by ${formatWhen(p.holdExpiresAt, p)}` : '';
    const lead = confirmed
      ? `${name} booked ${clean(p.serviceName)}. It was confirmed automatically (instant confirmation is on).`
      : `${name} requested ${clean(p.serviceName)} and verified their email address. Please confirm or decline${by}; after that the time is released.`;
    const customer = [
      ['Name', clean(p.customerName)],
      ['Email', clean(p.customerEmail)],
      ['Phone', clean(p.customerPhone)],
      ['Notes', clean(p.notes, 1000)],
    ].filter(([, v]) => v);
    const link = safeUrl(adminUrl);
    return {
      subject: `${confirmed ? 'New booking' : 'New booking request'}: ${name}, ${formatShort(p.startsAt, p)}`,
      preheader: confirmed ? 'Confirmed automatically.' : 'Needs your confirmation.',
      replyTo: clean(p.customerEmail) || undefined,
      text: [
        lead,
        detailsText(p),
        customer.map(([k, v]) => `${k}: ${v}`).join('\n'),
        link ? `Open your dashboard: ${link}` : 'Open your booking dashboard to manage it.',
        `Reply to this email to write to the customer.`,
      ],
      html: [
        para(esc(lead)),
        detailsHtml(p),
        table(customer),
        link ? button(link, 'Open your dashboard') : para('Open your booking dashboard to manage it.'),
        muted('Reply to this email to write to the customer.'),
      ],
    };
  },

  test(p, { business }) {
    return {
      subject: `Test email from your booking system`,
      preheader: `Email sending works.`,
      text: [
        `This is a test email from the booking system of ${business}.`,
        `Email sending works: customers will receive their booking codes and updates from this address.`,
      ],
      html: [
        para(`This is a test email from the booking system of <strong>${esc(business)}</strong>.`),
        para(`Email sending works: customers will receive their booking codes and updates from this address.`),
      ],
    };
  },
};

// ------------------------------------------------------------- formatting --

// Replies reach the business only when it has a public email (it becomes the
// Reply-To); otherwise customers are pointed to the phone, never to the
// unattended sending address.
function reach(p, business) {
  if (clean(p.businessEmail)) return `Reply to this email or contact ${business}`;
  const phone = clean(p.businessPhone);
  return phone ? `Call ${business} on ${phone}` : `Contact ${business}`;
}

function orReach(p, business) {
  if (clean(p.businessEmail)) return ', or reply to this email';
  const phone = clean(p.businessPhone);
  return phone ? `, or call ${business} on ${phone}` : '';
}

const lower = (s) => s.charAt(0).toLowerCase() + s.slice(1);

function greeting(p) {
  const name = clean(p.customerName);
  return name ? `Hi ${name.split(/\s+/)[0]},` : 'Hello,';
}

function details(p) {
  const rows = [
    ['Service', clean(p.serviceName)],
    ['When', formatWhen(p.startsAt, p)],
    ['Reference', clean(p.reference)],
  ];
  const price = formatPrice(p.priceCents, p.currency, p.locale);
  if (price) rows.push(['Price', price]);
  if (clean(p.address)) rows.push(['Where', clean(p.address)]);
  return rows;
}

const detailsText = (p) => details(p).map(([k, v]) => `${k}: ${v}`).join('\n');
const detailsHtml = (p) => table(details(p));

function intl(locale, options) {
  try {
    return new Intl.DateTimeFormat(locale || 'en-US', options);
  } catch {
    return new Intl.DateTimeFormat('en-US', { ...options, timeZone: 'UTC' });
  }
}

export function formatWhen(iso, p) {
  if (!iso) return '';
  return intl(p.locale, {
    timeZone: p.timezone || 'UTC',
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(iso));
}

function formatShort(iso, p) {
  if (!iso) return '';
  return intl(p.locale, {
    timeZone: p.timezone || 'UTC',
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(iso));
}

function formatPrice(cents, currency, locale) {
  if (typeof cents !== 'number' || !currency) return '';
  try {
    return new Intl.NumberFormat(locale || 'en-US', { style: 'currency', currency }).format(cents / 100);
  } catch {
    return `${(cents / 100).toFixed(2)} ${currency}`;
  }
}

/** Plain text from the payload: no control characters, bounded length. */
function clean(value, max = 200) {
  if (value === null || value === undefined) return '';
  return String(value).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '').trim().slice(0, max);
}

const oneLine = (s) => s.replace(/\s+/g, ' ').trim().slice(0, 200);

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function safeUrl(url) {
  if (!url) return '';
  try {
    const u = new URL(url);
    const local = u.hostname === 'localhost' || u.hostname === '127.0.0.1';
    return u.protocol === 'https:' || (local && u.protocol === 'http:') ? u.toString() : '';
  } catch {
    return '';
  }
}

// ------------------------------------------------------------------- HTML --

const FONT = "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

const para = (html) => `<p style="margin:0 0 16px;font-size:16px;line-height:1.5;color:#1f2328">${html}</p>`;
const muted = (html) => `<p style="margin:0 0 16px;font-size:14px;line-height:1.5;color:#59636e">${html}</p>`;

function codeBox(code) {
  return `<p style="margin:8px 0 24px;font-size:32px;font-weight:700;letter-spacing:6px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#1f2328">${esc(code)}</p>`;
}

function table(rows) {
  if (!rows.length) return '';
  const tr = rows
    .map(
      ([k, v]) =>
        `<tr><td style="padding:6px 16px 6px 0;font-size:14px;color:#59636e;vertical-align:top;white-space:nowrap">${esc(k)}</td>` +
        `<td style="padding:6px 0;font-size:15px;color:#1f2328;vertical-align:top">${esc(v).replace(/\n/g, '<br>')}</td></tr>`,
    )
    .join('');
  return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 20px;border-collapse:collapse">${tr}</table>`;
}

function button(href, label) {
  return `<p style="margin:0 0 20px"><a href="${esc(href)}" style="display:inline-block;padding:10px 18px;border-radius:6px;background:#1f2328;color:#ffffff;text-decoration:none;font-size:15px">${esc(label)}</a></p>`;
}

function layout({ business, preheader, blocks, contact }) {
  return [
    '<!doctype html>',
    '<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>',
    `<body style="margin:0;padding:0;background:#f6f8fa;${FONT}">`,
    `<div style="display:none;max-height:0;overflow:hidden">${esc(preheader ?? '')}</div>`,
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f8fa"><tr><td align="center" style="padding:24px 12px">',
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border:1px solid #d1d9e0;border-radius:8px">',
    `<tr><td style="padding:24px 28px 8px;font-size:18px;font-weight:600;color:#1f2328;${FONT}">${esc(business)}</td></tr>`,
    `<tr><td style="padding:8px 28px 12px;${FONT}">${blocks.filter(Boolean).join('')}</td></tr>`,
    `<tr><td style="padding:16px 28px 24px;border-top:1px solid #d1d9e0;font-size:13px;line-height:1.5;color:#59636e;${FONT}">${[business, ...contact].map(esc).join('<br>')}</td></tr>`,
    '</table></td></tr></table></body></html>',
  ].join('');
}
