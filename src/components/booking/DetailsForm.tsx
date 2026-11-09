import { useRef, useState } from 'react';
import type { FormEvent, ReactNode } from 'react';
import { NOTES_MAX, validateDetails, validateField } from './details';
import type { DetailField, Details, FieldErrors } from './details';

interface DetailsFormProps {
  details: Details;
  onChange: (details: Details) => void;
  errors: FieldErrors;
  onErrors: (errors: FieldErrors) => void;
  requirePhone: boolean;
  busy: boolean;
  notice: ReactNode;
  onSubmit: () => void;
  onBack: () => void;
}

export function DetailsForm({ details, onChange, errors, onErrors, requirePhone, busy, notice, onSubmit, onBack }: DetailsFormProps) {
  const [touched, setTouched] = useState<Partial<Record<DetailField, boolean>>>({});
  const nameRef = useRef<HTMLInputElement>(null);
  const emailRef = useRef<HTMLInputElement>(null);
  const phoneRef = useRef<HTMLInputElement>(null);
  const notesRef = useRef<HTMLTextAreaElement>(null);

  const update = (field: DetailField, value: string) => {
    const next = { ...details, [field]: value };
    onChange(next);
    // Once a field has shown a problem, re-check it as the guest types so the message clears.
    if (errors[field] || field === 'notes') onErrors({ ...errors, [field]: validateField(field, next, requirePhone) });
  };

  const blur = (field: DetailField) => {
    setTouched((t) => ({ ...t, [field]: true }));
    if (details[field].trim() || touched[field]) onErrors({ ...errors, [field]: validateField(field, details, requirePhone) });
  };

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (busy) return;
    const found = validateDetails(details, requirePhone);
    onErrors(found);
    const first = (['name', 'email', 'phone', 'notes'] as const).find((f) => found[f]);
    if (first) {
      const target = { name: nameRef, email: emailRef, phone: phoneRef, notes: notesRef }[first];
      target.current?.focus();
      return;
    }
    onSubmit();
  };

  const describedBy = (field: DetailField, hint?: boolean) =>
    [hint ? `bf-${field}-hint` : null, errors[field] ? `bf-${field}-error` : null].filter(Boolean).join(' ') || undefined;

  return (
    <form className="details" noValidate onSubmit={submit}>
      {notice}
      <div className="field">
        <label htmlFor="bf-name">Your name</label>
        <input
          ref={nameRef}
          id="bf-name"
          name="name"
          type="text"
          autoComplete="name"
          autoCapitalize="words"
          enterKeyHint="next"
          required
          value={details.name}
          aria-invalid={errors.name ? true : undefined}
          aria-describedby={describedBy('name')}
          onChange={(e) => update('name', e.target.value)}
          onBlur={() => blur('name')}
        />
        {errors.name && (
          <p className="field__error" id="bf-name-error">
            {errors.name}
          </p>
        )}
      </div>

      <div className="field">
        <label htmlFor="bf-email">Email</label>
        <p className="field__hint" id="bf-email-hint">
          {__BOOKING_DEMO__ ? 'In this demo no email is sent — you’ll type any 6 digits next.' : 'We’ll send a 6-digit code here to confirm it’s you.'}
        </p>
        <input
          ref={emailRef}
          id="bf-email"
          name="email"
          type="email"
          inputMode="email"
          autoComplete="email"
          autoCapitalize="none"
          spellCheck={false}
          enterKeyHint="next"
          required
          value={details.email}
          aria-invalid={errors.email ? true : undefined}
          aria-describedby={describedBy('email', true)}
          onChange={(e) => update('email', e.target.value)}
          onBlur={() => blur('email')}
        />
        {errors.email && (
          <p className="field__error" id="bf-email-error">
            {errors.email}
          </p>
        )}
      </div>

      <div className="field">
        <label htmlFor="bf-phone">
          Phone{!requirePhone && <span className="field__optional"> (optional)</span>}
        </label>
        <p className="field__hint" id="bf-phone-hint">
          Only used if we need to reach you about this appointment.
        </p>
        <input
          ref={phoneRef}
          id="bf-phone"
          name="phone"
          type="tel"
          inputMode="tel"
          autoComplete="tel"
          enterKeyHint="next"
          required={requirePhone}
          value={details.phone}
          aria-invalid={errors.phone ? true : undefined}
          aria-describedby={describedBy('phone', true)}
          onChange={(e) => update('phone', e.target.value)}
          onBlur={() => blur('phone')}
        />
        {errors.phone && (
          <p className="field__error" id="bf-phone-error">
            {errors.phone}
          </p>
        )}
      </div>

      <div className="field">
        <label htmlFor="bf-notes">
          About your dog<span className="field__optional"> (optional)</span>
        </label>
        <p className="field__hint" id="bf-notes-hint">
          Your dog’s name, breed or rough size, the coat’s condition (any knots or matting?) and how you’d like them to look. Anything
          that helps — nervous of dryers, sore hips, a first groom. No medical records needed.
        </p>
        <textarea
          ref={notesRef}
          id="bf-notes"
          name="notes"
          rows={3}
          value={details.notes}
          aria-invalid={errors.notes ? true : undefined}
          aria-describedby={describedBy('notes', true)}
          onChange={(e) => update('notes', e.target.value)}
          onBlur={() => blur('notes')}
        />
        <p className={`field__count ${details.notes.length > NOTES_MAX ? 'field__count--over' : ''}`} aria-live="polite">
          {details.notes.length > NOTES_MAX - 150 ? `${details.notes.length} / ${NOTES_MAX}` : ''}
        </p>
        {errors.notes && (
          <p className="field__error" id="bf-notes-error">
            {errors.notes}
          </p>
        )}
      </div>

      <div className="step-actions">
        <button type="submit" className="button" disabled={busy} aria-busy={busy || undefined}>
          {busy && <span className="busy" aria-hidden="true" />}
          {busy ? (__BOOKING_DEMO__ ? 'Holding your time…' : 'Sending your code…') : __BOOKING_DEMO__ ? 'Continue to the code' : 'Email me a code'}
        </button>
        <button type="button" className="link-button" onClick={onBack} disabled={busy}>
          Back to times
        </button>
      </div>
      <p className="fine-print">No account needed. We only use your details for your booking.</p>
    </form>
  );
}
