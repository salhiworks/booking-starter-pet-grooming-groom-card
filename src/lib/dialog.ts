import { useEffect, useRef, type RefObject } from 'react';

/** Keep the page behind still while the booking sheet is open. */
function syncScrollLock() {
  document.documentElement.classList.toggle('is-locked', Boolean(document.querySelector('dialog[open]')));
}

/**
 * A native modal <dialog> driven by React state: showModal() makes the rest of
 * the page inert and puts the sheet on top; Esc asks the owner to close (so
 * history and state stay in step); focus returns to whatever opened it.
 */
export function useModalDialog(ref: RefObject<HTMLDialogElement | null>, open: boolean, onClose: () => void) {
  const closeRef = useRef(onClose);
  useEffect(() => {
    closeRef.current = onClose;
  });

  const opener = useRef<HTMLElement | null>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) {
      opener.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      dialog.showModal();
    }
    if (!open && dialog.open) {
      dialog.close();
      const back = opener.current;
      requestAnimationFrame(() => {
        const lost = !document.activeElement || document.activeElement === document.body;
        if (back && lost && document.contains(back)) back.focus({ preventScroll: true });
      });
    }
    syncScrollLock();
  }, [ref, open]);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    const cancel = (event: Event) => {
      event.preventDefault();
      closeRef.current();
    };
    dialog.addEventListener('cancel', cancel);
    return () => dialog.removeEventListener('cancel', cancel);
  }, [ref]);

  useEffect(() => () => syncScrollLock(), []);
}
