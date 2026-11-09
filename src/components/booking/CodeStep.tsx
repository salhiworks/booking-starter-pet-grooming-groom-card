import { formatTime } from '@profitstudio/booking-engine';
import type { PendingVerification } from '@profitstudio/booking-engine';
import type { ClipboardEvent, FormEvent } from 'react';
import { Notice } from '../Notice';
import { cleanCode, sentence } from './details';

export type CodeBusy = null | 'verify' | 'resend' | 'switch' | 'edit';

interface CodeStepProps {
  pending: PendingVerification;
  timezone: string;
  locale: string;
  code: string;
  onCode: (code: string) => void;
  error: string | null;
  info: string | null;
  expired: boolean;
  canResend: boolean;
  busy: CodeBusy;
  onVerify: () => void;
  onResend: () => void;
  onAnotherTime: () => void;
  onEditEmail: () => void;
  /** The studio confirms each booking (`policies.autoConfirm` off): the code sends a request, not an appointment. */
  asRequest: boolean;
}

export function CodeStep(props: CodeStepProps) {
  const { pending, timezone, locale, code, onCode, error, info, expired, canResend, busy } = props;
  const until = formatTime(pending.expiresAt, timezone, locale);
  const preview = pending.delivery === 'preview';

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!busy) props.onVerify();
  };
  const paste = (event: ClipboardEvent<HTMLInputElement>) => {
    event.preventDefault();
    onCode(cleanCode(event.clipboardData.getData('text')));
  };

  return (
    <form className="code" noValidate onSubmit={submit}>
      {preview ? null : (
        <p className="code__sent">
          We sent a 6-digit code to <strong>{pending.email}</strong>. It works until <strong>{sentence(until)}</strong>
        </p>
      )}
      {preview && __BOOKING_DEMO__ ? (
        // Live Demo build only: the session is kept, in this browser, for the demo dashboard.
        <p className="code__preview">
          {props.asRequest
            ? 'Demo: no email was sent. Type any 6 digits — your request stays in this browser and waits in the demo dashboard for the studio to confirm.'
            : 'Demo: no email was sent. Type any 6 digits — your appointment stays in this browser and appears in the demo dashboard.'}
        </p>
      ) : preview ? (
        <p className="code__preview">Preview: no email was sent and nothing is saved. Type any 6 digits to continue.</p>
      ) : null}

      {expired ? (
        <Notice
          tone="error"
          action={{ label: 'Choose a time again', onClick: props.onAnotherTime, busy: busy === 'switch', busyLabel: 'One moment…' }}
        >
          <p>This code has run out, so the time was released. Choose your time again and we'll send a new code.</p>
        </Notice>
      ) : (
        <>
          <div className="field field--code">
            <label htmlFor="bf-code">6-digit code</label>
            <input
              id="bf-code"
              className="code__input"
              name="code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9]*"
              enterKeyHint="done"
              value={code}
              aria-invalid={error ? true : undefined}
              aria-describedby={['bf-code-spam', error ? 'bf-code-error' : null].filter(Boolean).join(' ')}
              onChange={(e) => onCode(cleanCode(e.target.value))}
              onPaste={paste}
            />
            {error && (
              <p className="field__error" id="bf-code-error" role="alert">
                {error}
              </p>
            )}
            {info && (
              <p className="field__info" role="status">
                {info}
              </p>
            )}
            <p className="field__hint" id="bf-code-spam">
              {__BOOKING_DEMO__
                ? 'Nothing to look for in this demo — any 6 digits will do.'
                : "Can't see it? It can take a minute — and check your spam or promotions folder."}
            </p>
          </div>

          <div className="step-actions">
            <button type="submit" className="button" disabled={busy !== null} aria-busy={busy === 'verify' || undefined}>
              {busy === 'verify' && <span className="busy" aria-hidden="true" />}
              {busy === 'verify' ? 'Checking your code…' : props.asRequest ? 'Send my request' : 'Confirm my appointment'}
            </button>
          </div>

          <div className="code__more">
            {pending.resendsLeft > 0 ? (
              <div className="code__resend">
                <button
                  type="button"
                  className="link-button"
                  onClick={props.onResend}
                  disabled={!canResend || busy !== null}
                  aria-busy={busy === 'resend' || undefined}
                  aria-describedby={canResend ? undefined : 'bf-code-wait'}
                >
                  {busy === 'resend' ? 'Sending a new code…' : 'Send a new code'}
                </button>
                {!canResend && (
                  <p className="code__wait" id="bf-code-wait">
                    You can ask for a new code after a minute.
                  </p>
                )}
              </div>
            ) : (
              <p className="code__wait">No more new codes can be sent for this request — the one you have works until {sentence(until)}</p>
            )}
            <p>
              <button
                type="button"
                className="link-button"
                onClick={props.onAnotherTime}
                disabled={busy !== null}
                aria-busy={busy === 'switch' || undefined}
              >
                {busy === 'switch' ? 'Releasing this time…' : 'Choose another time'}
              </button>
            </p>
            <p>
              <button
                type="button"
                className="link-button"
                onClick={props.onEditEmail}
                disabled={busy !== null}
                aria-busy={busy === 'edit' || undefined}
              >
                {busy === 'edit' ? 'One moment…' : 'Wrong email address? Change it'}
              </button>
            </p>
          </div>
        </>
      )}
    </form>
  );
}
