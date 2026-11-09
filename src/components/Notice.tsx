import type { ReactNode } from 'react';

interface NoticeProps {
  tone?: 'info' | 'error';
  children: ReactNode;
  action?: { label: string; onClick: () => void; busy?: boolean; busyLabel?: string };
  /** Errors are announced; set false for a notice that is part of a static state. */
  announce?: boolean;
}

/** A calm notice: a hairline on the left, plain text and at most one action. */
export function Notice({ tone = 'info', children, action, announce = true }: NoticeProps) {
  const role = announce ? (tone === 'error' ? 'alert' : 'status') : undefined;
  return (
    <div className={`notice notice--${tone}`} role={role}>
      <div className="notice__text">{children}</div>
      {action && (
        <button type="button" className="link-button" onClick={action.onClick} disabled={action.busy} aria-busy={action.busy || undefined}>
          {action.busy ? (action.busyLabel ?? action.label) : action.label}
        </button>
      )}
    </div>
  );
}
