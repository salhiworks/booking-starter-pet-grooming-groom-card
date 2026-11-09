/** A tel: link from a phone number as the owner wrote it ("+1 604-555-0148" → "tel:+16045550148"). */
export const telHref = (phone: string) => `tel:${phone.replace(/[^\d+]/g, '')}`;
