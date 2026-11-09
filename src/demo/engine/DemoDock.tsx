// VENDORED from booking-niche-packs/shared/demo-engine — edit it there, then run scripts/sync-shared.mjs.
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import type { DemoEngine } from './createDemoEngine';
import './demoBar.css';

/**
 * The Live Demo's one piece of chrome: a small floating "liquid glass" dock.
 *
 *   ● Live demo  |  ▦ Dashboard  |  ···
 *
 * Bottom-left on desktop, bottom-centre on phones, fixed to the viewport and
 * outside the page flow, so the website's own header is the first thing on the
 * page. It is the same on every Niche Pack design (neutral glass, no theme
 * colour) and only exists in a demo build: every starter mounts it behind
 * `__BOOKING_DEMO__`, which compiles it out of a real site.
 *
 * It never gets in the way of the website or the dashboard:
 * - a modal is open (any `<dialog open>` or `html.is-locked`, which is how every
 *   booking sheet and menu sheet in the collection opens) → it steps aside;
 * - a pinned control sits in its corner (a sticky/fixed button, link or field —
 *   the dashboard's tab bar, sidebar footer or Publish bar, a site's own sticky
 *   bar) → it lifts above it; ordinary content simply scrolls underneath;
 * - a text field has focus on a touch screen (the keyboard is up) → it hides.
 *
 * Inside the Profit Studio viewer (an iframe; detected with `window.top`, which
 * is readable cross-origin) the viewer already switches Website / Dashboard, so
 * the dock drops its own button and keeps "Open dashboard" in its menu.
 */

type Page = 'site' | 'admin';
type Panel = null | 'menu' | 'about' | 'confirm';

const ABOUT = 'This is a demo. Bookings and changes stay in this browser. No emails are sent.';
const REST_AFTER_MS = 4500;

function isEmbedded(): boolean {
  try {
    return window.self !== window.top;
  } catch {
    return true;
  }
}

/** A modal is showing: a native modal dialog, or the page's own scroll lock. */
function modalOpen(): boolean {
  return Boolean(document.querySelector('dialog[open]')) || document.documentElement.classList.contains('is-locked');
}

const INTERACTIVE = 'a[href],button,input,select,textarea,summary,[role="button"],[role="tab"],[role="link"],[tabindex]:not([tabindex="-1"])';

function isPinned(el: Element | null): boolean {
  for (let n: Element | null = el; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
    const position = getComputedStyle(n).position;
    if (position === 'fixed' || position === 'sticky') return true;
  }
  return false;
}

/**
 * What the dock must not cover: the visible, hit-testable buttons, links and
 * fields that sit in a fixed or sticky container in the lower part of the screen
 * (a tab bar, a Publish bar, a sidebar footer, a site's own sticky bar) — each
 * with the bar-sized group around it. Ordinary content is not listed: it scrolls
 * out from under the dock.
 */
function pinnedControls(host: HTMLElement): DOMRect[] {
  const fold = window.innerHeight * 0.4;
  const rects: DOMRect[] = [];
  for (const el of document.querySelectorAll<HTMLElement>(INTERACTIVE)) {
    if (host.contains(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1 || r.bottom < fold || r.top > window.innerHeight) continue;
    if (!isPinned(el)) continue;
    const x = Math.min(Math.max(r.left + r.width / 2, 0), window.innerWidth - 1);
    const y = Math.min(Math.max(r.top + r.height / 2, 0), window.innerHeight - 1);
    const top = document.elementsFromPoint(x, y).find((hit) => !host.contains(hit));
    if (!top || !(top === el || el.contains(top))) continue;
    // Avoid the control's whole group — the Publish bar with its note, the tab bar,
    // the sidebar footer — climbing while the box stays bar-sized (≤ 30% of the screen).
    let group = r;
    for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) {
      const box = n.getBoundingClientRect();
      if (box.height > window.innerHeight * 0.3) break;
      group = box;
      const position = getComputedStyle(n).position;
      if (position === 'fixed' || position === 'sticky') break;
    }
    if (!rects.some((o) => o.left === group.left && o.top === group.top && o.right === group.right && o.bottom === group.bottom)) rects.push(group);
  }
  return rects;
}

const GAP = 8; // breathing room between the dock and a pinned control

/** The smallest upward lift (px) that clears every pinned control; null when there is none within half the screen. */
function liftFor(base: DOMRect, obstacles: DOMRect[]): number | null {
  const max = Math.round(window.innerHeight * 0.5);
  for (let lift = 0; lift <= max; lift += 4) {
    const top = base.top - lift - GAP;
    const bottom = base.bottom - lift + GAP;
    const left = base.left - GAP;
    const right = base.right + GAP;
    if (!obstacles.some((o) => o.right > left && o.left < right && o.bottom > top && o.top < bottom)) return lift;
  }
  return null;
}

function Icon({ name }: { name: 'dashboard' | 'website' | 'more' | 'reset' | 'info' | 'close' }) {
  const paths: Record<typeof name, string> = {
    dashboard: 'M4 4h6v7H4zM14 4h6v4h-6zM14 12h6v8h-6zM4 15h6v5H4z',
    website: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3.6 9h16.8M3.6 15h16.8M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z',
    more: '',
    reset: 'M4 12a8 8 0 1 0 2.4-5.7M4 4v4.5h4.5',
    info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5M12 7.6v.1',
    close: 'M6 6l12 12M18 6 6 18',
  };
  if (name === 'more') {
    return (
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">
        <circle cx="5.5" cy="12" r="1.6" fill="currentColor" />
        <circle cx="12" cy="12" r="1.6" fill="currentColor" />
        <circle cx="18.5" cy="12" r="1.6" fill="currentColor" />
      </svg>
    );
  }
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
      <path d={paths[name]} fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function DemoDock({ engine, page, host }: { engine: DemoEngine; page: Page; host: HTMLElement }) {
  const embedded = isEmbedded();
  const [panel, setPanel] = useState<Panel>(null);
  const [booked, setBooked] = useState<string | null>(null);
  const [stepAside, setStepAside] = useState(false);
  const [typing, setTyping] = useState(false);
  const [resting, setResting] = useState(false);
  const [lift, setLift] = useState(0);
  // Icon-only, when the full dock finds no clear spot (e.g. beside a sticky editor list).
  const [compact, setCompact] = useState(false);
  const [entered, setEntered] = useState(false);
  const dockRef = useRef<HTMLDivElement>(null);
  const moreRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const restTimer = useRef<number | undefined>(undefined);
  const ids = useId();
  const menuId = `${ids}-menu`;
  const aboutId = `${ids}-about`;

  const hidden = stepAside || typing;
  // A panel never stays open behind a modal or under the keyboard.
  const open: Panel = hidden ? null : panel;
  const otherPage = page === 'site' ? { href: '/admin/#bookings', label: 'Dashboard', menuLabel: 'Open dashboard', icon: 'dashboard' as const } : { href: '/', label: 'Website', menuLabel: 'View website', icon: 'website' as const };

  // ── Entrance, and resting after a while without interaction ─────────
  useEffect(() => {
    const frame = requestAnimationFrame(() => setEntered(true));
    return () => cancelAnimationFrame(frame);
  }, []);

  const restLater = useCallback(() => {
    window.clearTimeout(restTimer.current);
    restTimer.current = window.setTimeout(() => setResting(true), REST_AFTER_MS);
  }, []);
  const wake = useCallback(() => {
    setResting(false);
    restLater();
  }, [restLater]);
  // The quiet countdown restarts whenever a panel closes (and on first show).
  useEffect(() => {
    if (!panel) restLater();
    else window.clearTimeout(restTimer.current);
    return () => window.clearTimeout(restTimer.current);
  }, [panel, restLater]);

  // ── A request was just made on the website: point at the dashboard ──
  useEffect(() => {
    const onBooked = (e: Event) => {
      setBooked((e as CustomEvent<{ reference: string }>).detail.reference);
      wake();
    };
    window.addEventListener('booking-demo:booked', onBooked);
    return () => window.removeEventListener('booking-demo:booked', onBooked);
  }, [wake]);

  // ── Step aside while a modal (booking sheet, menu sheet) is open ────
  useEffect(() => {
    const sync = () => setStepAside(modalOpen());
    sync();
    const observer = new MutationObserver(sync);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
    observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['open'] });
    return () => observer.disconnect();
  }, []);

  // ── Hide while the on-screen keyboard is up (a field focused on touch) ─
  useEffect(() => {
    const coarse = window.matchMedia('(pointer: coarse)');
    const editable = (el: EventTarget | null) =>
      el instanceof HTMLElement && (el.matches('input:not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]),textarea,select') || el.isContentEditable);
    const onIn = (e: FocusEvent) => {
      if (coarse.matches && editable(e.target) && !host.contains(e.target as Node)) setTyping(true);
    };
    const onOut = () => requestAnimationFrame(() => setTyping(coarse.matches && editable(document.activeElement) && !host.contains(document.activeElement)));
    document.addEventListener('focusin', onIn);
    document.addEventListener('focusout', onOut);
    return () => {
      document.removeEventListener('focusin', onIn);
      document.removeEventListener('focusout', onOut);
    };
  }, [host]);

  // ── Lift above pinned controls in its corner (tab bars, Publish bars…) ─
  const place = useCallback(() => {
    const dock = dockRef.current;
    if (!dock || hidden) return;
    // Where it sits with no lift, from layout (not the box on screen, which includes
    // the transform and its transition).
    const cs = getComputedStyle(dock);
    const width = dock.offsetWidth;
    const height = dock.offsetHeight;
    const left = parseFloat(cs.left) + parseFloat(cs.marginLeft); // margins resolve to px (auto-centred on phones)
    const base = new DOMRect(left, window.innerHeight - parseFloat(cs.bottom) - height, width, height);
    const next = liftFor(base, pinnedControls(host));
    if (next === null && !compact) {
      setCompact(true); // re-placed once the narrower dock has rendered
      return;
    }
    const lifted = next ?? 0;
    setLift((current) => (current === lifted ? current : lifted));
  }, [host, hidden, compact]);

  useLayoutEffect(() => {
    let frame = 0;
    let timer = 0;
    const schedule = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        cancelAnimationFrame(frame);
        frame = requestAnimationFrame(place);
      }, 120);
    };
    // A new page or size: try the full dock again.
    const reset = () => {
      setCompact(false);
      schedule();
    };
    schedule();
    window.addEventListener('resize', reset);
    window.addEventListener('scroll', schedule, { passive: true, capture: true });
    window.addEventListener('hashchange', reset);
    const observer = new MutationObserver(schedule);
    observer.observe(document.body, { subtree: true, childList: true });
    return () => {
      window.clearTimeout(timer);
      cancelAnimationFrame(frame);
      window.removeEventListener('resize', reset);
      window.removeEventListener('scroll', schedule, { capture: true });
      window.removeEventListener('hashchange', reset);
      observer.disconnect();
    };
  }, [place]);

  // ── Menu: outside click and Escape close it; focus moves in and back ─
  useEffect(() => {
    if (!open) return;
    const onPointer = (e: PointerEvent) => {
      if (!host.contains(e.target as Node)) setPanel(null);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        setPanel(null);
        moreRef.current?.focus();
      }
    };
    document.addEventListener('pointerdown', onPointer, true);
    document.addEventListener('keydown', onKey, true);
    return () => {
      document.removeEventListener('pointerdown', onPointer, true);
      document.removeEventListener('keydown', onKey, true);
    };
  }, [open, host]);

  useEffect(() => {
    if (!open) return;
    const frame = requestAnimationFrame(() => {
      const first = menuRef.current?.querySelector<HTMLElement>(open === 'menu' ? '[role="menuitem"]' : '[data-autofocus]');
      first?.focus();
    });
    return () => cancelAnimationFrame(frame);
  }, [open]);

  const onMenuKey = (e: ReactKeyboardEvent<HTMLDivElement>) => {
    if (open !== 'menu') return;
    const items = [...(menuRef.current?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])];
    const at = items.indexOf(document.activeElement as HTMLElement);
    let next = -1;
    if (e.key === 'ArrowDown') next = (at + 1) % items.length;
    else if (e.key === 'ArrowUp') next = (at - 1 + items.length) % items.length;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = items.length - 1;
    else if (e.key === 'Tab') setPanel(null);
    if (next >= 0) {
      e.preventDefault();
      items[next]?.focus();
    }
  };

  const reset = () => {
    engine.resetDemo();
    window.location.assign(page === 'admin' ? '/admin/' : '/');
  };

  const className = [
    'bdock',
    entered ? 'is-in' : '',
    resting && !open ? 'is-resting' : '',
    hidden ? 'is-aside' : '',
    embedded ? 'is-embedded' : '',
    compact ? 'is-compact' : '',
    open ? 'is-open' : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div
      ref={dockRef}
      className={className}
      role="region"
      aria-label="Live demo controls"
      style={lift ? ({ '--bdock-lift': `${-lift}px` } as CSSProperties) : undefined}
      onPointerEnter={wake}
      onPointerDown={wake}
      onFocus={wake}
      // Out of the way: not focusable or announced while it has stepped aside.
      inert={hidden || undefined}
      aria-hidden={hidden || undefined}
    >
      <div className="bdock-bar">
        <button
          type="button"
          className="bdock-status"
          aria-expanded={open === 'about'}
          aria-controls={aboutId}
          onClick={() => setPanel(open === 'about' ? null : 'about')}
          title="About this demo"
          aria-label={compact ? `${page === 'admin' ? 'Demo dashboard' : 'Live demo'} — about this demo` : undefined}
        >
          <span className="bdock-dot" aria-hidden="true" />
          <span className="bdock-label">{page === 'admin' ? 'Demo dashboard' : 'Live demo'}</span>
        </button>

        {!embedded && (
          <>
            <span className="bdock-sep" aria-hidden="true" />
            <a className={`bdock-btn${booked && page === 'site' ? ' is-hint' : ''}`} href={otherPage.href} aria-label={compact ? otherPage.label : undefined}>
              <Icon name={otherPage.icon} />
              <span className="bdock-text-label">{otherPage.label}</span>
              {booked && page === 'site' && <span className="bdock-badge" aria-hidden="true" />}
            </a>
          </>
        )}

        <span className="bdock-sep" aria-hidden="true" />
        <button
          ref={moreRef}
          type="button"
          className="bdock-icon"
          aria-label="More demo options"
          aria-haspopup="menu"
          aria-expanded={open === 'menu' || open === 'confirm'}
          aria-controls={menuId}
          onClick={() => setPanel(open === 'menu' || open === 'confirm' ? null : 'menu')}
        >
          <Icon name="more" />
        </button>
      </div>

      <span className="bdock-live" aria-live="polite">
        {booked && page === 'site' ? `Request ${booked} is waiting in the demo dashboard.` : ''}
      </span>

      {open === 'menu' && (
        <div ref={menuRef} id={menuId} className="bdock-pop" role="menu" aria-label="Demo options" onKeyDown={onMenuKey}>
          {embedded && (
            <a role="menuitem" tabIndex={-1} className="bdock-item" href={otherPage.href}>
              <Icon name={otherPage.icon} />
              {otherPage.menuLabel}
            </a>
          )}
          <button role="menuitem" tabIndex={-1} type="button" className="bdock-item" onClick={() => setPanel('confirm')}>
            <Icon name="reset" />
            Reset demo
          </button>
          <button role="menuitem" tabIndex={-1} type="button" className="bdock-item" onClick={() => setPanel('about')}>
            <Icon name="info" />
            About this demo
          </button>
        </div>
      )}

      {open === 'confirm' && (
        <div ref={menuRef} id={menuId} className="bdock-pop bdock-pop--card" role="alertdialog" aria-labelledby={`${ids}-confirm`} aria-describedby={`${ids}-confirm-text`}>
          <p className="bdock-title" id={`${ids}-confirm`}>
            Reset the demo?
          </p>
          <p className="bdock-text" id={`${ids}-confirm-text`}>
            Bookings, prices, hours and website edits made in this browser go back to the sample data.
          </p>
          <div className="bdock-actions">
            <button type="button" className="bdock-action" data-autofocus="" onClick={() => setPanel(null)}>
              Cancel
            </button>
            <button type="button" className="bdock-action bdock-action--strong" onClick={reset}>
              Reset everything
            </button>
          </div>
        </div>
      )}

      {open === 'about' && (
        <div ref={menuRef} id={aboutId} className="bdock-pop bdock-pop--card" role="dialog" aria-label="About this demo">
          <div className="bdock-row">
            <p className="bdock-title">About this demo</p>
            <button type="button" className="bdock-icon bdock-icon--small" aria-label="Close" data-autofocus="" onClick={() => setPanel(null)}>
              <Icon name="close" />
            </button>
          </div>
          <p className="bdock-text">{ABOUT}</p>
          <p className="bdock-text bdock-text--muted">
            {page === 'admin'
              ? 'The dashboard shows sample bookings. Answer requests, change prices or hours, then see the website.'
              : 'Book a time as a guest, then manage it in the dashboard as the owner.'}
          </p>
        </div>
      )}
    </div>
  );
}
