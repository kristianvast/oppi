/**
 * Server-side OSC 7501 program status: one derivation, one owner.
 *
 * Every status surface (session list, app events, Live Activity, push, CLI `wait`) reads
 * `Session.programStatus` produced here. Lifecycle `Session.status` stays as is and only
 * drives controls.
 *
 * Two layers, both in this file:
 * - `trackProgramRunEvent` folds Pi events into a small run tracker. It mirrors Pi 1.1.0's own
 *   terminal reporter (`ProgramStatusReporter`): the latest assistant response decides a run's
 *   outcome, so a retried error is replaced by its successful retry, and `agent_settled.aborted`
 *   means idle.
 * - `deriveProgramStatus` is the pure table: lifecycle status + tracker + pending dialogs.
 *
 * Privacy line (same as Pi): messages are the session name, a dialog title, the first question
 * of an `ask`, or the first line of an error. Never prompts or model output.
 */

import { isPendingUserReplyRequest } from "./session-attention.js";
import type { ProgramStatus, ProgramStatusKind, Session } from "./types.js";

/** Outcome of a run while no run is active. */
interface RestingOutcome {
  state: "done" | "error" | "idle";
  /** Error outcomes carry the first line of the error. */
  message?: string;
}

/** Event-folded run state. In-memory; the resting outcome survives restarts through `Session.programStatus`. */
export interface ProgramRunTracker {
  runActive: boolean;
  compacting: boolean;
  /** Outcome of the current run, applied when it settles. */
  runResult: RestingOutcome;
  /** Outcome while no run is active. */
  resting: RestingOutcome;
}

/** Pending dialog fields the derivation reads; satisfied by `ExtensionUIRequest`. */
interface ProgramStatusDialog {
  type?: string;
  method?: string;
  title?: string;
  questions?: unknown;
  options?: unknown;
}

/** Anything that owns a session plus live runtime state: active sessions, mirror sessions, startup state. */
export interface ProgramStatusHost {
  session: Session;
  /** Live runtime-owned work that can wake an idle parent; never persisted as liveness. */
  backgroundActivityCount?: number;
  pendingUIRequests?: ReadonlyMap<string, ProgramStatusDialog>;
  programRun?: ProgramRunTracker;
}

export interface ProgramStatusSync {
  previous: ProgramStatus | undefined;
  current: ProgramStatus;
  /** State, kind, or message differs from the previous value. */
  changed: boolean;
  /**
   * While blocked on a question: the question with its choices, for the push body. Never
   * stored or sent as program status, whose message stays the bare question.
   */
  blockedDetail?: string;
}

/** Notified when a sync changes a session's state, kind, or message. */
export type ProgramStatusChangeListener = (session: Session, change: ProgramStatusSync) => void;

const MAX_MESSAGE_LENGTH = 512;
const COMPACTING_MESSAGE = "Compacting context";

/** One display line: control characters (including newlines) become spaces, then trim and cap. */
function oneLine(text: string | undefined): string | undefined {
  if (typeof text !== "string") return undefined;
  const line = text
    // eslint-disable-next-line no-control-regex
    .replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, " ")
    .trim();
  if (line.length === 0) return undefined;
  return line.length > MAX_MESSAGE_LENGTH ? `${line.slice(0, MAX_MESSAGE_LENGTH - 1)}…` : line;
}

function firstLine(text: unknown): string | undefined {
  if (typeof text !== "string") return undefined;
  return oneLine(text.split(/\r?\n/, 1)[0]);
}

function errorOutcome(text: unknown): RestingOutcome {
  const message = firstLine(text);
  return message ? { state: "error", message } : { state: "error" };
}

export function newProgramRunTracker(persisted?: ProgramStatus): ProgramRunTracker {
  const resting: RestingOutcome =
    persisted?.state === "done" || persisted?.state === "idle"
      ? { state: persisted.state }
      : persisted?.state === "error"
        ? errorOutcome(persisted.message)
        : { state: "idle" };
  return { runActive: false, compacting: false, runResult: { state: "done" }, resting };
}

/** Pi event shapes this tracker reads. Loose on purpose: the mirror forwards raw JSON from older and newer Pi TUIs. */
interface ProgramRunEvent {
  type: string;
  aborted?: unknown;
  reason?: unknown;
  errorMessage?: unknown;
  message?: { role?: unknown; stopReason?: unknown; errorMessage?: unknown };
}

export function trackProgramRunEvent(tracker: ProgramRunTracker, event: ProgramRunEvent): void {
  switch (event.type) {
    case "agent_start":
      tracker.runActive = true;
      tracker.runResult = { state: "done" };
      return;
    case "message_end":
      // The latest response decides the outcome, so a retried error is replaced by its retry.
      if (event.message?.role !== "assistant") return;
      tracker.runResult =
        event.message.stopReason === "error"
          ? errorOutcome(event.message.errorMessage)
          : { state: "done" };
      return;
    case "compaction_start":
      tracker.compacting = true;
      return;
    case "compaction_end": {
      tracker.compacting = false;
      const aborted = event.aborted === true;
      if (tracker.runActive) {
        // A failed recovery compaction ends the run unless a later response succeeds.
        if (aborted) tracker.runResult = { state: "idle" };
        else if (event.errorMessage) tracker.runResult = errorOutcome(event.errorMessage);
      } else if (aborted) {
        tracker.resting = { state: "idle" };
      } else if (event.reason === "manual") {
        tracker.resting = event.errorMessage ? errorOutcome(event.errorMessage) : { state: "done" };
      }
      return;
    }
    case "agent_settled":
      tracker.runActive = false;
      // `aborted` exists from Pi 1.1.0; older mirrored TUIs omit it and count as finished.
      tracker.resting = event.aborted === true ? { state: "idle" } : tracker.runResult;
      return;
    default:
      return;
  }
}

function blockedFromDialog(dialog: ProgramStatusDialog): {
  kind: ProgramStatusKind;
  message?: string;
} {
  if (dialog.method === "confirm") {
    return { kind: "permission", message: oneLine(dialog.title) };
  }
  if (dialog.method === "ask" && Array.isArray(dialog.questions)) {
    const first = dialog.questions[0] as { question?: unknown } | undefined;
    return {
      kind: "question",
      message: oneLine(typeof first?.question === "string" ? first.question : dialog.title),
    };
  }
  return { kind: "question", message: oneLine(dialog.title) };
}

function optionLabels(options: unknown): string[] {
  if (!Array.isArray(options)) return [];
  return options.flatMap((option: unknown) => {
    const label =
      typeof option === "string"
        ? option
        : typeof (option as { label?: unknown } | null)?.label === "string"
          ? (option as { label: string }).label
          : undefined;
    const line = oneLine(label);
    return line ? [line] : [];
  });
}

/**
 * What a question push says: the question, its choices, and how many questions follow.
 * Undefined for dialogs that are not questions, or questions without text.
 */
function questionDetail(dialog: ProgramStatusDialog): string | undefined {
  if (dialog.method === "ask" && Array.isArray(dialog.questions)) {
    const first = dialog.questions[0] as { question?: unknown; options?: unknown } | undefined;
    const question = oneLine(typeof first?.question === "string" ? first.question : dialog.title);
    if (!question) return undefined;
    const options = optionLabels(first?.options);
    const more = dialog.questions.length - 1;
    return [
      question,
      options.length > 0 ? `Options: ${options.join(", ")}` : undefined,
      more > 0 ? `(+${more} more ${more === 1 ? "question" : "questions"})` : undefined,
    ]
      .filter(Boolean)
      .join(" ");
  }
  if (dialog.method === "select") {
    const title = oneLine(dialog.title);
    if (!title) return undefined;
    const options = optionLabels(dialog.options);
    return options.length > 0 ? `${title} Options: ${options.join(", ")}` : title;
  }
  return undefined;
}

/** The most recent pending dialog that waits on the user, which is what `blocked` reports. */
function blockingDialog(pending: Iterable<ProgramStatusDialog>): ProgramStatusDialog | undefined {
  let blocking: ProgramStatusDialog | undefined;
  for (const dialog of pending) {
    if (isPendingUserReplyRequest(dialog)) blocking = dialog;
  }
  return blocking;
}

function lifecycleErrorMessage(session: Session): string | undefined {
  // A typed launch failure stores its machine code (`agent_tools_unavailable`) in promptError;
  // that is not a line a person should read, and clients render typed failures themselves.
  const promptError = session.launch?.failure ? undefined : session.launch?.promptError;
  return firstLine(promptError) ?? firstLine(session.warnings?.at(-1));
}

function withMessage(
  state: ProgramStatus["state"],
  message: string | undefined,
): Omit<ProgramStatus, "since"> {
  return message === undefined ? { state } : { state, message };
}

/**
 * The derivation table. `pending` lists open dialogs in the order they opened; the most recent
 * blocking one wins.
 */
export function deriveProgramStatus(input: {
  session: Session;
  tracker: ProgramRunTracker;
  backgroundActivityCount?: number;
  pending: Iterable<ProgramStatusDialog>;
  now: number;
}): ProgramStatus {
  const { session, now } = input;
  const body = deriveBody(input);
  const previous = session.programStatus;
  // `since` is when this state began: keep it while state and kind are unchanged.
  const since =
    previous && previous.state === body.state && previous.kind === body.kind ? previous.since : now;
  return { ...body, since };
}

function deriveBody(input: {
  session: Session;
  tracker: ProgramRunTracker;
  backgroundActivityCount?: number;
  pending: Iterable<ProgramStatusDialog>;
}): Omit<ProgramStatus, "since"> {
  const { session, tracker } = input;

  if (session.status === "stopped") {
    // Last outcome retained; a run cut short by the stop has no outcome.
    return {
      state:
        tracker.runActive || (input.backgroundActivityCount ?? 0) > 0
          ? "idle"
          : tracker.resting.state,
    };
  }
  if (session.status === "error") {
    return withMessage("error", lifecycleErrorMessage(session));
  }

  const blocking = blockingDialog(input.pending);
  if (blocking) {
    const { kind, message } = blockedFromDialog(blocking);
    return { ...withMessage("blocked", message), kind };
  }

  if (tracker.compacting) return { state: "working", message: COMPACTING_MESSAGE };

  // `agent_end` clears the turn marker before `agent_settled`, so a stop in that gap has no
  // turn but its run is still unsettled.
  const working =
    session.status === "starting" ||
    session.status === "busy" ||
    (session.status === "stopping" &&
      (session.currentTurnStartedAt !== undefined || tracker.runActive));
  if (working) return withMessage("working", oneLine(session.name));

  const count = input.backgroundActivityCount ?? 0;
  if (count > 0) {
    return {
      state: "working",
      message: `Waiting on ${count} background ${count === 1 ? "activity" : "activities"}`,
    };
  }

  // A run the lifecycle already calls settled but whose `agent_settled` we never saw (a mirrored
  // TUI that reported idle first) ends with its own result, not the previous run's.
  const resting = tracker.runActive ? tracker.runResult : tracker.resting;
  if (resting.state === "done") return withMessage("done", oneLine(session.name));
  return withMessage(resting.state, resting.message);
}

/** The host's run tracker, created from the persisted outcome on first use. */
export function programRunFor(host: ProgramStatusHost): ProgramRunTracker {
  host.programRun ??= newProgramRunTracker(host.session.programStatus);
  return host.programRun;
}

/**
 * Recompute and store `session.programStatus` from the host's live state. Idempotent; call it
 * after anything that can change the inputs. The previous value gates `since`, so repeated
 * calls never churn the wire value.
 */
export function syncProgramStatus(host: ProgramStatusHost, now = Date.now()): ProgramStatusSync {
  const { session } = host;
  const previous = session.programStatus;
  const pending = [...(host.pendingUIRequests?.values() ?? [])];
  const current = deriveProgramStatus({
    session,
    tracker: programRunFor(host),
    backgroundActivityCount: host.backgroundActivityCount,
    pending,
    now,
  });
  const changed =
    !previous ||
    previous.state !== current.state ||
    previous.kind !== current.kind ||
    previous.message !== current.message;
  if (changed || previous?.since !== current.since) {
    session.programStatus = current;
  }
  const blocking = current.state === "blocked" ? blockingDialog(pending) : undefined;
  const blockedDetail = blocking ? questionDetail(blocking) : undefined;
  return { previous, current, changed, ...(blockedDetail ? { blockedDetail } : {}) };
}
