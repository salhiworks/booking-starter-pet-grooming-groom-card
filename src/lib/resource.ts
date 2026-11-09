import { useCallback, useEffect, useRef, useState } from 'react';
import type { EngineError, Result } from '@profitstudio/booking-engine';

export type Resource<T> =
  | { status: 'loading' }
  | { status: 'ready'; data: T }
  | { status: 'error'; error: EngineError };

/** Calls an engine read once on mount; `reload()` calls it again. Stale answers are ignored. */
export function useEngineResource<T>(load: () => Promise<Result<T>>): [Resource<T>, () => void] {
  const [state, setState] = useState<Resource<T>>({ status: 'loading' });
  const call = useRef(0);

  const fetchLatest = useCallback(() => {
    const id = ++call.current;
    load()
      .then((result) => {
        if (id !== call.current) return;
        setState(result.ok ? { status: 'ready', data: result.data } : { status: 'error', error: result.error });
      })
      .catch(() => {
        if (id !== call.current) return;
        setState({ status: 'error', error: { code: 'UNKNOWN', message: 'Something went wrong.' } });
      });
  }, [load]);

  useEffect(() => {
    fetchLatest();
  }, [fetchLatest]);

  const reload = useCallback(() => {
    // A failed read shows its loading state again; a loaded one stays on screen while it refreshes.
    setState((current) => (current.status === 'error' ? { status: 'loading' } : current));
    fetchLatest();
  }, [fetchLatest]);

  return [state, reload];
}
