/** The guest's details, kept while they move back and forth in the flow. */
export interface Details {
  name: string;
  email: string;
  phone: string;
  notes: string;
}

export type DetailField = keyof Details;
export type FieldErrors = Partial<Record<DetailField, string>>;

export const NOTES_MAX = 1000;

const hasControlCharacters = (value: string) =>
  [...value].some((ch) => {
    const code = ch.charCodeAt(0);
    return code < 32 || code === 127;
  });

/** The engine's rules (INTEGRATION.md §7), checked in the browser first for inline, specific messages. */
export function validateField(field: DetailField, details: Details, requirePhone: boolean): string | undefined {
  switch (field) {
    case 'name': {
      const name = details.name.trim();
      if (!name) return 'Please tell us your name.';
      if (name.length > 120) return 'Please keep your name to 120 characters.';
      if (hasControlCharacters(name)) return 'Please use letters, spaces and punctuation only.';
      return undefined;
    }
    case 'email': {
      const email = details.email.trim();
      if (!email) return 'Please add your email address — your code is sent there.';
      if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$/.test(email)) {
        return 'Please check your email address — it should look like name@example.com.';
      }
      return undefined;
    }
    case 'phone': {
      const phone = details.phone.trim();
      if (!phone) return requirePhone ? 'Please add a phone number, so we can text you when your dog is ready.' : undefined;
      if (phone.length > 40 || !/^[\d\s+()./-]+$/.test(phone) || phone.replace(/\D/g, '').length < 5) {
        return 'Please check the phone number — digits, spaces and + ( ) - only.';
      }
      return undefined;
    }
    case 'notes':
      return details.notes.length > NOTES_MAX ? `Please keep your note to ${NOTES_MAX} characters.` : undefined;
  }
}

export function validateDetails(details: Details, requirePhone: boolean): FieldErrors {
  const errors: FieldErrors = {};
  for (const field of ['name', 'email', 'phone', 'notes'] as const) {
    const problem = validateField(field, details, requirePhone);
    if (problem) errors[field] = problem;
  }
  return errors;
}

/** The engine names fields like "customer.email"; the form uses "email". */
export function formField(engineField: string | undefined): DetailField | null {
  switch (engineField) {
    case 'customer.name':
      return 'name';
    case 'customer.email':
      return 'email';
    case 'customer.phone':
      return 'phone';
    case 'notes':
      return 'notes';
    default:
      return null;
  }
}

export const reducedMotion = () =>
  typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Digits only, at most 6 — on input and on paste ("123 456", "123-456"). */
export const cleanCode = (value: string) => value.replace(/\D/g, '').slice(0, 6);

/** Ends a sentence once: en-CA times already end in a period ("4:12 p.m."). */
export const sentence = (text: string) => (/[.!?]$/.test(text) ? text : `${text}.`);
