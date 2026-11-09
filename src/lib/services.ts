import { formatMoney } from '@profitstudio/booking-engine';
import type { Service } from '@profitstudio/booking-engine';

/**
 * The grooming menu's kinds and sizes, and who each service is for.
 *
 * The engine (2.0.0-beta.3) has no service categories, no size or weight
 * pricing and no per-service metadata, and a service's id is a database UUID
 * this site cannot know when it is built — so everything here is read from the
 * service's own engine data:
 *
 *   1. its KIND (Full grooms · Baths & coat care · Puppies · Tidies & nails), from
 *      its NAME against the rules below — first match wins, strongest signal first
 *      ("Puppy Introduction" is a puppy visit even though it includes a bath;
 *      "Face, Feet & Hygiene Tidy" is a tidy, not a full groom); if the name has no
 *      grooming words, its DESCRIPTION; otherwise "More services";
 *   2. its SIZE (small · medium · large), from the size words in its NAME
 *      ("Full Groom — Small Dog", "Bath & Brush — Small & Medium Dog"); a name
 *      without a size word suits every size;
 *   3. who it is for: the part of its description after "For:" (or "Suits:" /
 *      "Good for:"), split at "·" — written by the owner in Dashboard → Services.
 *
 * Choosing a size on the page only FILTERS the list: the price of each service is
 * the engine's own. A stable category or size field needs an engine version — see
 * docs/ENGINE-PROPOSAL-pet-grooming.md in the Niche Pack workspace.
 */
export type KindId = 'full' | 'bath' | 'puppy' | 'tidy' | 'more';
export type SizeId = 'small' | 'medium' | 'large';

/** Content fields that belong to a kind (src/content/site.ts). */
export type KindNote = 'services.noteFull' | 'services.noteBath' | 'services.notePuppy' | 'services.noteTidy';

interface KindRule {
  id: KindId;
  label: string;
  note: KindNote | null;
  match: RegExp;
}

const RULES: KindRule[] = [
  {
    id: 'puppy',
    label: 'Puppies',
    note: 'services.notePuppy',
    match: /\b(pupp(?:y|ies)|first groom|introduc(?:tion|tory)|intro)\b/i,
  },
  {
    id: 'tidy',
    label: 'Tidies & nails',
    note: 'services.noteTidy',
    match: /\b(nails?|tidy|tidies|face|feet|paws?|hygiene|sanitary|teeth|ears?|quick)\b/i,
  },
  {
    id: 'bath',
    label: 'Baths & coat care',
    note: 'services.noteBath',
    match: /\b(bath(?:e|s)?|wash|brush(?:-?out)?|deshed(?:ding)?|shed(?:ding)?|undercoat|blow-?out|de-?matt(?:ing)?|coat care)\b/i,
  },
  {
    id: 'full',
    label: 'Full grooms',
    note: 'services.noteFull',
    match: /\b(full groom|groom(?:ing)?|haircut|hair cut|clip(?:per)?|scissor(?:ed|ing)?|trim|style|cut)\b/i,
  },
];

const MORE = { id: 'more', label: 'More services', note: null } as const;

/** The order kinds are shown in. */
const ORDER: KindId[] = ['full', 'bath', 'puppy', 'tidy', 'more'];

export const SIZES: Array<{ id: SizeId; label: string }> = [
  { id: 'small', label: 'Small' },
  { id: 'medium', label: 'Medium' },
  { id: 'large', label: 'Large' },
];

const SIZE_WORDS: Record<SizeId, RegExp> = {
  small: /\b(small|toy|mini|x-?small|petite)\b/i,
  medium: /\b(medium|mid-?size)\b/i,
  large: /\b(large|big|x-?large|giant)\b/i,
};

export interface Kind {
  id: KindId;
  label: string;
  note: KindNote | null;
  services: Service[];
}

export function kindOf(service: Pick<Service, 'name' | 'description'>): KindRule | typeof MORE {
  const byName = RULES.find((rule) => rule.match.test(service.name));
  if (byName) return byName;
  const { lead } = splitDescription(service.description);
  return RULES.find((rule) => rule.match.test(lead)) ?? MORE;
}

/** The sizes a service names; an empty list means "every size". */
export function sizesOf(service: Pick<Service, 'name'>): SizeId[] {
  return SIZES.filter((s) => SIZE_WORDS[s.id].test(service.name)).map((s) => s.id);
}

/** Does the service suit a dog of this size? (No size chosen, or no size in its name: yes.) */
export function fitsSize(service: Pick<Service, 'name'>, size: SizeId | null): boolean {
  if (!size) return true;
  const sizes = sizesOf(service);
  return sizes.length === 0 || sizes.includes(size);
}

/** Do any services name a size? (Only then does the page offer the size picker.) */
export function hasSizes(services: readonly Service[]): boolean {
  return services.some((s) => sizesOf(s).length > 0);
}

/**
 * The service name without its size, and the size as a short tag:
 * "Full Groom — Small Dog" → { base: "Full Groom", size: "Small Dog" }.
 * Names without a dash or a size word come back whole.
 */
export function splitName(name: string): { base: string; size: string | null } {
  const match = /^(.*?)\s*[—–-]\s*(.+)$/.exec(name);
  if (match && SIZES.some((s) => SIZE_WORDS[s.id].test(match[2]))) return { base: match[1], size: match[2] };
  return { base: name, size: null };
}

/** Services in their kinds, keeping the owner's display order inside each; empty kinds are left out. */
export function kinds(services: readonly Service[]): Kind[] {
  const map = new Map<KindId, Kind>();
  for (const service of services) {
    const rule = kindOf(service);
    let k = map.get(rule.id);
    if (!k) {
      k = { id: rule.id, label: rule.label, note: rule.note, services: [] };
      map.set(rule.id, k);
    }
    k.services.push(service);
  }
  return ORDER.flatMap((id) => (map.has(id) ? [map.get(id)!] : []));
}

/**
 * "A warm bath… For: short coats · between full grooms" →
 * { lead: "A warm bath…", suits: ["short coats", "between full grooms"] }.
 * Without "For:" the whole description is the lead and the list is empty.
 */
export function splitDescription(description: string | null | undefined): { lead: string; suits: string[] } {
  const text = (description ?? '').trim();
  const match = /(?:^|[\s.])(?:for|suits|suited to|good for|ideal for|best for)\s*:\s*/i.exec(text);
  if (!match) return { lead: text, suits: [] };
  const lead = text.slice(0, match.index + (match[0].startsWith('.') ? 1 : 0)).trim();
  const suits = text
    .slice(match.index + match[0].length)
    .split(/\s*[·•;]\s*|\s+\|\s+/)
    .map((item) => item.trim().replace(/\.$/, ''))
    .filter(Boolean);
  return { lead, suits };
}

/** "45 min", "2 h", "2 h 30 min" — the time the dog is booked in, straight from the engine. */
export function durationLabel(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m ? `${h} h ${m} min` : `${h} h`;
}

/** The same, for screen readers. */
export function durationSpoken(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${minutes} minutes`;
  const hours = `${h} hour${h > 1 ? 's' : ''}`;
  return m ? `${hours} ${m} minutes` : hours;
}

export function priceLabel(service: Pick<Service, 'priceCents' | 'priceFrom' | 'currency'>, locale: string): string {
  if (service.priceCents === null) return 'Price on request';
  const amount = formatMoney(service.priceCents, service.currency, locale);
  return service.priceFrom ? `from ${amount}` : amount;
}

/**
 * The price as the menu shows it: the amount, and whether it is a starting
 * price ("from" — the engine's `priceFrom`). Whole dollars print without ".00".
 */
export function priceParts(service: Pick<Service, 'priceCents' | 'priceFrom' | 'currency'>, locale: string): { from: boolean; amount: string } {
  if (service.priceCents === null) return { from: false, amount: 'Price on request' };
  return { from: service.priceFrom, amount: formatMoney(service.priceCents, service.currency, locale).replace(/([.,])00(?!\d)/, '') };
}

/** Whole-dollar prices print without ".00" — "from $85", not "from $85.00". */
export function shortPrice(service: Pick<Service, 'priceCents' | 'priceFrom' | 'currency'>, locale: string): string {
  return priceLabel(service, locale).replace(/([.,])00(?!\d)/, '');
}
