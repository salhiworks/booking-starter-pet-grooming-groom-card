import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import {
  addDays,
  addMonths,
  firstDayOfWeek,
  formatClockTime,
  formatDate,
  formatTime,
  isDifferentTimeZone,
  monthGrid,
  monthOf,
  nextAvailableDay,
  timeZoneLabel,
  todayInTimeZone,
} from '@profitstudio/booking-engine';
import type {
  AvailabilityDay,
  Business,
  EngineError,
  PartOfDay,
  PendingVerification,
  Result,
  Service,
  Slot,
} from '@profitstudio/booking-engine';
import { telHref } from '../../lib/contact';
import { engine } from '../../lib/engine';
import { durationLabel, kinds, shortPrice, splitDescription, splitName } from '../../lib/services';
import { Notice } from '../Notice';
import { CodeStep } from './CodeStep';
import type { CodeBusy } from './CodeStep';
import { ContactInstead } from './ContactInstead';
import { DayPicker } from './DayPicker';
import { DetailsForm } from './DetailsForm';
import type { Details, FieldErrors } from './details';
import { formField, reducedMotion, sentence } from './details';
import { Done } from './Done';
import type { Outcome } from './Done';
import { Summary } from './Summary';
import { TimePicker } from './TimePicker';

type Step = 'service' | 'time' | 'details' | 'code' | 'done';
type Busy = null | 'request' | Exclude<CodeBusy, null>;
type Availability =
  | { status: 'idle' }
  | { status: 'loading'; month: string }
  | { status: 'ready'; month: string; days: AvailabilityDay[] }
  | { status: 'error'; month: string; error: EngineError };
type FlowNotice = { tone: 'info' | 'error'; text: string; contact?: boolean } | null;
type Stopped = null | 'paused' | 'not-configured' | 'unavailable';

const STEPS: Array<{ id: Exclude<Step, 'done'>; label: string; title: string }> = [
  { id: 'service', label: 'Service', title: 'Choose a service' },
  { id: 'time', label: 'Date & time', title: 'Choose a day and time' },
  { id: 'details', label: 'Your details', title: 'Your details' },
  // The Live Demo sends no email: its last step must not promise one.
  { id: 'code', label: __BOOKING_DEMO__ ? 'Confirm' : 'Confirm email', title: __BOOKING_DEMO__ ? 'Confirm it’s you' : 'Check your email' },
];

const TAKEN = 'That time is no longer available — it may have just been booked. Here are the times still open.';
const OFFLINE = "We couldn't reach the booking system. Please check your connection and try again.";
const UNKNOWN = 'Something went wrong on our side. Please try again in a moment.';
const RAN_OUT = 'Your code ran out, so the time was released. Choose a time again and we’ll send a new code.';
const ENDED = 'Your request has ended, so the time was released. Choose a time again and we’ll send a new code.';

export interface BookingIntent {
  /** A treatment chosen from the page, or null for a general “Book”. */
  serviceId: string | null;
  nonce: number;
}

interface BookingFlowProps {
  business: Business;
  services: Service[];
  intent: BookingIntent | null;
  onServicesStale: () => void;
}

async function safely<T>(call: () => Promise<Result<T>>): Promise<Result<T>> {
  try {
    return await call();
  } catch {
    return { ok: false, error: { code: 'UNKNOWN', message: UNKNOWN } };
  }
}

export function BookingFlow({ business, services, intent, onServicesStale }: BookingFlowProps) {
  const { timezone, locale, policies } = business;
  const today = todayInTimeZone(timezone);
  const lastDate = addDays(today, policies.maxAdvanceDays);
  const minMonth = monthOf(today);
  const maxMonth = monthOf(lastDate);
  const weekStart = firstDayOfWeek(locale);

  const [step, setStep] = useState<Step>('service');
  const [serviceId, setServiceId] = useState<string | null>(null);
  const [month, setMonth] = useState(minMonth);
  const [availability, setAvailability] = useState<Availability>({ status: 'idle' });
  const [date, setDate] = useState<string | null>(null);
  const [part, setPart] = useState<PartOfDay>('morning');
  const [slot, setSlot] = useState<Slot | null>(null);
  const [details, setDetails] = useState<Details>({ name: '', email: '', phone: '', notes: '' });
  const [fieldErrors, setFieldErrors] = useState<FieldErrors>({});
  const [pending, setPending] = useState<PendingVerification | null>(null);
  const [code, setCode] = useState('');
  const [codeError, setCodeError] = useState<string | null>(null);
  const [codeInfo, setCodeInfo] = useState<string | null>(null);
  const [resendWait, setResendWait] = useState<{ key: number; seconds: number } | null>(null);
  const [resendReadyKey, setResendReadyKey] = useState(-1);
  const [expiredAt, setExpiredAt] = useState<string | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
  const [notice, setNotice] = useState<FlowNotice>(null);
  const [outcome, setOutcome] = useState<Outcome | null>(null);
  const [stopped, setStopped] = useState<Stopped>(null);
  const [focusTick, setFocusTick] = useState(0);

  const headingRef = useRef<HTMLHeadingElement>(null);
  const loadSeq = useRef(0);
  const lastCode = useRef('');
  const autoSubmitted = useRef('');
  const resendKey = useRef(0);

  const service = services.find((s) => s.id === serviceId) ?? null;
  const days = availability.status === 'ready' ? availability.days : null;
  const day = days?.find((d) => d.date === date) ?? null;
  const canResend = resendWait !== null && resendReadyKey === resendWait.key;
  const expired = pending !== null && expiredAt === pending.expiresAt;

  // ── Navigation and focus ───────────────────────────────────────────
  const go = (next: Step) => {
    setStep(next);
    setFocusTick((t) => t + 1);
  };

  // Focus moves to each new step's heading (never on the first render).
  useEffect(() => {
    if (focusTick === 0) return;
    const heading = headingRef.current;
    if (!heading) return;
    heading.focus({ preventScroll: true });
    // Inside the sheet each step starts at its heading (scroll-margin keeps it clear of the phone's summary strip).
    heading.scrollIntoView({ block: 'start', behavior: reducedMotion() ? 'auto' : 'smooth' });
  }, [focusTick]);

  /** The chosen service was removed or paused by the owner meanwhile. */
  const serviceGone = () => {
    onServicesStale();
    setServiceId(null);
    setSlot(null);
    setNotice({ tone: 'error', text: 'That service can no longer be booked online. Please choose another one.' });
    go('service');
  };

  // ── Availability: one getAvailability call per visible month ────────
  const availabilityFailed = (error: EngineError, forMonth: string) => {
    switch (error.code) {
      case 'BOOKING_DISABLED':
        setStopped('paused');
        return;
      case 'NOT_CONFIGURED':
        setStopped('not-configured');
        return;
      case 'SCHEMA_MISSING':
      case 'SCHEMA_INCOMPATIBLE':
        setStopped('unavailable');
        return;
      case 'SERVICE_UNAVAILABLE':
        serviceGone();
        return;
      case 'INVALID_INPUT':
        if (error.field === 'serviceId') {
          serviceGone();
          return;
        }
        break;
    }
    setAvailability({ status: 'error', month: forMonth, error });
  };

  const loadAvailability = async (forMonth: string, forService: string, pick: 'keep' | 'first', advance = false) => {
    const id = ++loadSeq.current;
    let target = forMonth;
    for (;;) {
      const grid = monthGrid(target, weekStart);
      setAvailability({ status: 'loading', month: target });
      const result = await safely(() => engine.getAvailability({ serviceId: forService, from: grid.from, to: grid.to }));
      if (id !== loadSeq.current) return;
      if (!result.ok) {
        availabilityFailed(result.error, target);
        return;
      }
      const loaded = result.data.days;
      const first = nextAvailableDay(loaded.filter((d) => d.date >= today && d.date.startsWith(target)));
      // When a treatment is first chosen and this month has nothing left, show the next month that has times.
      if (!first && advance && target < maxMonth) {
        target = addMonths(target, 1);
        setMonth(target);
        continue;
      }
      setAvailability({ status: 'ready', month: target, days: loaded });
      setDate((current) => {
        const keepable = current !== null && loaded.some((d) => d.date === current && d.status !== 'unavailable');
        if (pick === 'keep' && keepable) return current;
        return first?.date ?? null;
      });
      return;
    }
  };

  const reloadTimes = () => {
    if (serviceId) void loadAvailability(month, serviceId, 'keep');
  };

  /** SLOT_UNAVAILABLE at the details step: say so and show fresh times. */
  const timeTaken = () => {
    setSlot(null);
    setNotice({ tone: 'error', text: TAKEN });
    go('time');
    reloadTimes();
  };

  /** The request ended at the code step: back to the times (the details stay), fresh availability. */
  const backToTimes = async (text: string) => {
    setPending(null);
    setSlot(null);
    setCode('');
    setNotice({ tone: 'error', text });
    go('time');
    if (serviceId) await loadAvailability(month, serviceId, 'keep');
  };

  // ── Step 4: the code → verifyBooking ───────────────────────────────
  const verify = async (value: string) => {
    if (!pending) return;
    if (value.length !== 6) {
      setCodeError('Please enter all 6 digits from the email.');
      return;
    }
    lastCode.current = value;
    setBusy('verify');
    setCodeError(null);
    setCodeInfo(null);
    const result = await safely(() => engine.verifyBooking({ requestId: pending.requestId, code: value }));
    setBusy(null);
    if (result.ok) {
      setOutcome({ kind: 'booked', confirmation: result.data, email: pending.email });
      setPending(null);
      go('done');
      return;
    }
    const error = result.error;
    switch (error.code) {
      case 'PREVIEW_MODE':
        setOutcome({ kind: 'preview' });
        setPending(null);
        go('done');
        return;
      case 'INVALID_CODE': {
        const left = error.attemptsLeft;
        setCodeError(
          left === undefined
            ? "That code doesn't match. Please check the email and try again."
            : `That code doesn't match. You have ${left} ${left === 1 ? 'try' : 'tries'} left.`,
        );
        return;
      }
      case 'INVALID_INPUT':
        if (error.field === 'requestId') {
          await backToTimes(ENDED);
        } else {
          setCodeError('Please enter the 6 digits from the email.');
        }
        return;
      case 'CODE_EXPIRED':
        await backToTimes(RAN_OUT);
        return;
      case 'TOO_MANY_ATTEMPTS':
        await backToTimes('The code was entered incorrectly too many times, so the time was released. Choose a time again for a new code.');
        return;
      case 'SLOT_UNAVAILABLE':
        await backToTimes(TAKEN);
        return;
      case 'TOO_MANY_BOOKINGS':
        setOutcome({ kind: 'limit' });
        setPending(null);
        go('done');
        return;
      case 'BOOKING_DISABLED':
        setStopped('paused');
        return;
      case 'RATE_LIMITED':
        setCodeError('Too many tries in a short time. Please wait a moment — or call or email the studio.');
        return;
      case 'NETWORK':
        setCodeError(OFFLINE);
        return;
      default:
        setCodeError(UNKNOWN);
    }
  };

  // ── Releasing a held time (the code step's ways back) ──────────────
  /** Resolves true when the hold is released (or had already ended); false when the code was already accepted. */
  const release = async (): Promise<boolean> => {
    if (!pending) return true;
    const result = await safely(() => engine.cancelBookingRequest(pending.requestId));
    if (!result.ok && result.error.code === 'CONFLICT' && result.error.field === 'already_verified') {
      // An earlier answer was lost: the code was accepted. Show the confirmation instead of going back.
      if (lastCode.current) await verify(lastCode.current);
      else setCodeInfo('Your code was already accepted — check your email for the details.');
      return false;
    }
    setPending(null);
    return true;
  };

  // ── Step 1: treatment and length ───────────────────────────────────
  const chooseService = async (id: string) => {
    if (pending) {
      setBusy('switch');
      const released = await release();
      setBusy(null);
      if (!released) return;
    }
    const firstChoice = serviceId === null;
    setServiceId(id);
    setSlot(null);
    setOutcome(null);
    setNotice(null);
    setCodeError(null);
    setCodeInfo(null);
    go('time');
    if (firstChoice) {
      setMonth(minMonth);
      await loadAvailability(minMonth, id, 'first', true);
    } else {
      await loadAvailability(month, id, 'keep', true);
    }
  };

  // The "Book" links in the treatments list arrive here.
  const onIntent = useRef<(id: string) => void>(() => {});
  useLayoutEffect(() => {
    onIntent.current = (id) => void chooseService(id);
  });
  useEffect(() => {
    if (intent?.serviceId) onIntent.current(intent.serviceId);
  }, [intent]);

  // ── Step 2: date and time ──────────────────────────────────────────
  const selectDate = (next: string) => {
    setDate(next);
    setSlot(null);
    if (notice?.tone === 'error') setNotice(null);
  };

  const changeMonth = (next: string) => {
    if (!serviceId || next < minMonth || next > maxMonth) return;
    setMonth(next);
    setSlot(null);
    void loadAvailability(next, serviceId, 'first');
  };

  // ── Step 3: details → requestBooking (holds the time, emails a code) ─
  const submitDetails = async () => {
    if (!service || !slot) return;
    setBusy('request');
    setNotice(null);
    const result = await safely(() =>
      engine.requestBooking({
        serviceId: service.id,
        startsAt: slot.startsAt, // unchanged, as getAvailability returned it
        customer: { name: details.name.trim(), email: details.email.trim(), phone: details.phone.trim() || null },
        notes: details.notes.trim() || null,
      }),
    );
    setBusy(null);
    if (result.ok) {
      setPending(result.data);
      setCode('');
      setCodeError(null);
      setCodeInfo(null);
      autoSubmitted.current = '';
      lastCode.current = '';
      setResendWait({ key: ++resendKey.current, seconds: result.data.resendAfterSeconds });
      go('code');
      return;
    }
    const error = result.error;
    switch (error.code) {
      case 'INVALID_INPUT': {
        const field = formField(error.field);
        if (field) {
          setFieldErrors((e) => ({ ...e, [field]: error.message }));
          document.getElementById(`bf-${field}`)?.focus();
        } else if (error.field === 'startsAt') {
          timeTaken();
        } else if (error.field === 'serviceId') {
          serviceGone();
        } else {
          setNotice({ tone: 'error', text: error.message });
        }
        return;
      }
      case 'SLOT_UNAVAILABLE':
        timeTaken();
        return;
      case 'SERVICE_UNAVAILABLE':
        serviceGone();
        return;
      case 'RATE_LIMITED':
        setNotice({
          tone: 'error',
          text: "We can't take this booking online right now. Please call or email the studio and we'll find you a time.",
          contact: true,
        });
        return;
      case 'BOOKING_DISABLED':
        setStopped('paused');
        return;
      case 'NOT_CONFIGURED':
        setStopped('not-configured');
        return;
      case 'SCHEMA_MISSING':
      case 'SCHEMA_INCOMPATIBLE':
        setStopped('unavailable');
        return;
      case 'NETWORK':
        setNotice({ tone: 'error', text: OFFLINE });
        return;
      default:
        setNotice({ tone: 'error', text: UNKNOWN });
    }
  };

  // ── Step 4: typing, new codes and the ways back ────────────────────
  const onCode = (value: string) => {
    setCode(value);
    if (codeError) setCodeError(null);
    // A complete code (typed or pasted) is checked at once — but never the same rejected code twice.
    if (value.length === 6 && value !== autoSubmitted.current && busy === null) {
      autoSubmitted.current = value;
      void verify(value);
    }
  };

  const resend = async () => {
    if (!pending) return;
    setBusy('resend');
    setCodeError(null);
    setCodeInfo(null);
    const result = await safely(() => engine.resendVerificationCode(pending.requestId));
    setBusy(null);
    const until = formatTime(pending.expiresAt, timezone, locale);
    if (result.ok) {
      setPending({ ...pending, ...result.data });
      setResendWait({ key: ++resendKey.current, seconds: result.data.resendAfterSeconds });
      setCode('');
      autoSubmitted.current = '';
      setCodeInfo(
        result.data.delivery === 'preview'
          ? `${__BOOKING_DEMO__ ? 'Demo' : 'Preview'}: no email was sent. Any 6 digits will do.`
          : `A new code is on its way to ${pending.email}. The previous one no longer works.`,
      );
      return;
    }
    const error = result.error;
    switch (error.code) {
      case 'RESEND_TOO_SOON':
        setResendWait({ key: ++resendKey.current, seconds: error.retryAfterSeconds ?? 30 });
        setCodeInfo('Please wait a few more seconds before asking for a new code.');
        return;
      case 'RESEND_LIMIT':
        // No more new codes — but the current one still works until expiresAt: stay here.
        setPending({ ...pending, resendsLeft: 0 });
        return;
      case 'RATE_LIMITED':
        setCodeInfo(`We can't send another code right now. The one you have still works until ${sentence(until)}`);
        return;
      case 'CONFLICT':
        if (error.field === 'already_verified') {
          await verify(lastCode.current || code);
          return;
        }
        setCodeError(UNKNOWN);
        return;
      case 'CODE_EXPIRED':
        await backToTimes(RAN_OUT);
        return;
      case 'INVALID_INPUT':
        await backToTimes(ENDED);
        return;
      case 'BOOKING_DISABLED':
        setStopped('paused');
        return;
      case 'NETWORK':
        setCodeError(OFFLINE);
        return;
      default:
        setCodeError(UNKNOWN);
    }
  };

  // "Choose another time": await the release, only then reload the times.
  const anotherTime = async () => {
    setBusy('switch');
    const released = await release();
    if (!released) {
      setBusy(null);
      return;
    }
    setSlot(null);
    setCode('');
    setNotice(null);
    go('time');
    if (serviceId) await loadAvailability(month, serviceId, 'keep');
    setBusy(null);
  };

  const editEmail = async () => {
    setBusy('edit');
    const released = await release();
    setBusy(null);
    if (!released) return;
    setCode('');
    go('details');
    window.setTimeout(() => document.getElementById('bf-email')?.focus(), 0);
  };

  // ── Summary actions ────────────────────────────────────────────────
  const changeTreatment = async () => {
    if (pending) {
      setBusy('switch');
      const released = await release();
      setBusy(null);
      if (!released) return;
    }
    setNotice(null);
    go('service');
  };

  const changeTime = () => {
    if (pending) void anotherTime();
    else {
      setNotice(null);
      go('time');
    }
  };

  const startAgain = () => {
    setOutcome(null);
    setServiceId(null);
    setSlot(null);
    setDate(null);
    setAvailability({ status: 'idle' });
    setDetails((d) => ({ ...d, notes: '' }));
    setNotice(null);
    go('service');
  };

  // ── Timers: "Send a new code" after resendAfterSeconds; the code's end ─
  useEffect(() => {
    if (!resendWait) return;
    const timer = window.setTimeout(() => setResendReadyKey(resendWait.key), resendWait.seconds * 1000);
    return () => window.clearTimeout(timer);
  }, [resendWait]);

  const expiresAt = pending?.expiresAt ?? null;
  useEffect(() => {
    if (!expiresAt) return;
    const timer = window.setTimeout(() => setExpiredAt(expiresAt), Math.max(0, Date.parse(expiresAt) - Date.now()));
    return () => window.clearTimeout(timer);
  }, [expiresAt]);

  // ── Render ─────────────────────────────────────────────────────────
  if (stopped) {
    const copy = {
      paused: {
        title: 'Book by phone or email for now',
        text: "Online booking is switched off at the moment. Call or email the studio and we'll find you a time.",
      },
      'not-configured': { title: 'Online booking is not available yet', text: 'Please call or email the studio to book an appointment.' },
      unavailable: {
        title: 'Online booking is temporarily unavailable',
        text: "Please call or email the studio and we'll find you a time.",
      },
    }[stopped];
    return <ContactInstead business={business} title={copy.title} text={copy.text} />;
  }

  const currentIndex = STEPS.findIndex((s) => s.id === step);
  const current = STEPS[currentIndex];
  const differentZone = isDifferentTimeZone(timezone);
  const contactNotice = notice?.contact ? business.contact : null;

  return (
    <div className="flow" id="book-flow" data-step={step}>
      {step !== 'done' && (
        <ol className="flow__steps" aria-label="Booking steps">
          {STEPS.map((s, i) => (
            <li
              key={s.id}
              className={i < currentIndex ? 'is-done' : i === currentIndex ? 'is-current' : ''}
              aria-current={i === currentIndex ? 'step' : undefined}
            >
              <span className="flow__step-n" aria-hidden="true">
                {i + 1}
              </span>
              <span className="flow__step-label">{s.label}</span>
            </li>
          ))}
        </ol>
      )}

      <div className="flow__body">
        {step !== 'done' && (
          <Summary
            business={business}
            service={service}
            date={step === 'service' ? null : date}
            slot={slot}
            canChangeTime={step === 'details' || step === 'code'}
            onChangeTreatment={() => void changeTreatment()}
            onChangeTime={changeTime}
            busy={busy !== null}
          />
        )}

        <div className="flow__main">
          {step === 'done' && outcome ? (
            <Done outcome={outcome} business={business} headingRef={headingRef} onAgain={startAgain} />
          ) : (
            <div className="flow__step" key={step}>
              <p className="flow__counter">
                Step {currentIndex + 1} of {STEPS.length}
              </p>
              <h2 className="step-title" tabIndex={-1} ref={headingRef} data-step-heading="">
                {current.title}
              </h2>

              {notice && (
                <Notice tone={notice.tone}>
                  <p>{notice.text}</p>
                  {contactNotice && (contactNotice.phone || contactNotice.email) && (
                    <p className="notice__contact">
                      {contactNotice.phone && <a href={telHref(contactNotice.phone)}>{contactNotice.phone}</a>}
                      {contactNotice.phone && contactNotice.email && ' · '}
                      {contactNotice.email && <a href={`mailto:${contactNotice.email}`}>{contactNotice.email}</a>}
                    </p>
                  )}
                </Notice>
              )}

              {step === 'service' && (
                <ServiceStep services={services} selected={serviceId} locale={locale} busy={busy !== null} onChoose={(id) => void chooseService(id)} />
              )}

              {step === 'time' && (
                <div className="time-step">
                  {availability.status === 'error' ? (
                    <Notice tone="error" action={{ label: 'Try again', onClick: reloadTimes }}>
                      <p>{availability.error.code === 'NETWORK' ? OFFLINE : "We couldn't load the calendar just now."}</p>
                    </Notice>
                  ) : (
                    <>
                      <DayPicker
                        month={month}
                        minMonth={minMonth}
                        maxMonth={maxMonth}
                        weekStart={weekStart}
                        days={days}
                        today={today}
                        selected={date}
                        locale={locale}
                        onSelect={selectDate}
                        onMonth={changeMonth}
                      />
                      {days === null ? (
                        <div className="times-block times-block--loading" aria-hidden="true">
                          <span className="skeleton skeleton--parts" />
                          <span className="skeleton skeleton--times" />
                        </div>
                      ) : (
                        <TimePicker
                          day={day}
                          days={days}
                          monthLabel={formatDate(`${month}-01`, locale, { month: 'long' })}
                          part={part}
                          onPart={setPart}
                          selected={slot}
                          onSelect={setSlot}
                          onJump={(target) => {
                            if (target.startsWith(month)) selectDate(target);
                            else if (serviceId) {
                              setMonth(monthOf(target));
                              setDate(target);
                              void loadAvailability(monthOf(target), serviceId, 'keep');
                            }
                          }}
                          onNextMonth={month < maxMonth ? () => changeMonth(addMonths(month, 1)) : null}
                          locale={locale}
                        />
                      )}
                      <p className="zone-note">
                        {differentZone ? 'Times shown in ' : 'All times are '}
                        {timeZoneLabel(timezone, locale)}
                        {differentZone ? ', the studio’s local time.' : '.'}
                      </p>
                    </>
                  )}
                  {slot && date && (
                    <div className="choice-bar">
                      <p className="choice-bar__text">
                        <span>{formatDate(date, locale, { weekday: 'short', month: 'short', day: 'numeric' })}</span>
                        <strong>{formatClockTime(slot.time, locale)}</strong>
                      </p>
                      <button type="button" className="button" onClick={() => go('details')}>
                        Continue
                      </button>
                    </div>
                  )}
                </div>
              )}

              {step === 'details' && (
                <DetailsForm
                  details={details}
                  onChange={setDetails}
                  errors={fieldErrors}
                  onErrors={setFieldErrors}
                  requirePhone={policies.requirePhone}
                  busy={busy === 'request'}
                  notice={null}
                  onSubmit={() => void submitDetails()}
                  onBack={() => go('time')}
                />
              )}

              {step === 'code' && pending && (
                <CodeStep
                  asRequest={!policies.autoConfirm}
                  pending={pending}
                  timezone={timezone}
                  locale={locale}
                  code={code}
                  onCode={onCode}
                  error={codeError}
                  info={codeInfo}
                  expired={expired}
                  canResend={canResend}
                  busy={busy === 'request' ? null : busy}
                  onVerify={() => void verify(code)}
                  onResend={() => void resend()}
                  onAnotherTime={() => void anotherTime()}
                  onEditEmail={() => void editEmail()}
                />
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

interface ServiceStepProps {
  services: Service[];
  selected: string | null;
  locale: string;
  busy: boolean;
  onChoose: (id: string) => void;
}

/**
 * Services in the same kinds as the menu on the page (Full grooms, Baths & coat care…);
 * each shows the dog size from its name as a tag, the time booked, the price and who it is for.
 */
function ServiceStep({ services, selected, locale, busy, onChoose }: ServiceStepProps) {
  const groups = kinds(services);
  return (
    <ul className="pick-list" role="list">
      {groups.map((g) => (
        <li className="pick-group" key={g.id} data-group={g.id}>
          {groups.length > 1 && <h3 className="pick-group__title">{g.label}</h3>}
          <ul className="pick-lengths" role="list">
            {g.services.map((s) => {
              const { base, size } = splitName(s.name);
              return (
                <li key={s.id}>
                  <button type="button" className="pick" aria-pressed={s.id === selected} disabled={busy} onClick={() => onChoose(s.id)}>
                    <span className="pick__name">
                      {base}
                      {size && (
                        <>
                          <span className="sr-only"> — </span>
                          <span className="pick__size">{size}</span>
                        </>
                      )}
                    </span>
                    <span className="pick__meta">
                      <span className="pick__duration">{durationLabel(s.durationMinutes)}</span>
                      <span className="pick__price">{shortPrice(s, locale)}</span>
                    </span>
                    <PickDescription description={s.description} />
                    <span className="pick__arrow" aria-hidden="true">
                      →
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
        </li>
      ))}
    </ul>
  );
}

/** The service's description, with who it is for as a short line of its own. */
function PickDescription({ description }: { description: string | null }) {
  const { lead, suits } = splitDescription(description);
  if (!lead && suits.length === 0) return null;
  return (
    <span className="pick__desc">
      {lead}
      {suits.length > 0 && (
        <span className="pick__includes">
          <span className="pick__includes-label">For </span>
          {suits.join(' · ')}
        </span>
      )}
    </span>
  );
}
