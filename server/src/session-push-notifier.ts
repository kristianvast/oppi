import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { PushNotification, PushSender } from "./push/push-sender.js";
import type { ProgramStatusSync } from "./program-status.js";
import type { SessionBroadcastEvent } from "./session-broadcast.js";
import { sessionEndIsTerminalOwned } from "./session-runtime-capabilities.js";
import type { Storage } from "./storage.js";
import type { ProgramStatusKind, Session, SessionPushEvent } from "./types.js";

const log = createLogger({ base: { component: "session_push_notifier" } });
const GENERIC_SESSION_ERROR_REASON = "Open Oppi to review the session error.";

/** Shortest gap between two pushes of the same kind for one session. */
const PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS = 60_000;

/** Longest workspace label in a title, and longest detail line in a body (code points). */
const TITLE_WORKSPACE_MAX = 30;
const BODY_DETAIL_MAX = 240;

function clip(value: string | undefined, max: number): string | undefined {
  const line = value?.replace(/\s+/g, " ").trim();
  if (!line) return undefined;
  const points = Array.from(line);
  return points.length <= max ? line : `${points.slice(0, max - 1).join("")}…`;
}

const BLOCKED_PRESENTATION = {
  permission: { title: "Needs Approval", body: "Waiting for your approval." },
  question: { title: "Question", body: "Waiting for your answer." },
  auth: { title: "Sign-in Needed", body: "Waiting for you to sign in." },
} as const;

type PushEventContent = {
  event: SessionPushEvent;
  kind?: ProgramStatusKind;
  title: string;
  body: string;
  /** The body says something specific to this event, not the fixed fallback text. */
  detailed: boolean;
};

export interface SessionPushNotifierOptions {
  /** True while this paired device holds a live app-event or focused session stream. */
  isDevicePresent: (deviceId: string) => boolean;
  now?: () => number;
}

/**
 * Sends end-to-end-encrypted session alerts through the push relay (protocol/push/spec.md).
 *
 * `ended` and `error` fire on their lifecycle events. `blocked` and `done` fire on program
 * status transitions, at most once a minute per session and kind, and skip each device that
 * is present (holds a live stream, so the app already shows the change or posts its own
 * banner). An open Mac or iPad never silences the phone. `done` is for top-level sessions
 * only; delegated sessions report to their parent, but their `blocked` still pushes.
 * Each device gets its own sealed envelope; a device without a push key gets nothing.
 */
export class SessionPushNotifier {
  private readonly lastProgramPushAt = new Map<string, number>();
  private readonly now: () => number;

  constructor(
    private readonly push: PushSender,
    private readonly storage: Storage,
    private readonly options: SessionPushNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  handleSessionEvent(payload: SessionBroadcastEvent): void {
    const content = this.contentForEvent(payload);
    if (!content) {
      return;
    }
    this.deliver(payload.sessionId, content, {
      skipPresent: false,
      // Closing or reloading a mirrored terminal is the user's own action at the Mac.
      skipMirroredTerminal: content.event === "ended",
    });
  }

  /** Push on entering `blocked` or `done`. Same-state updates (message, kind) never push. */
  handleProgramStatusChange(session: Session, change: ProgramStatusSync): void {
    const { previous, current } = change;
    if (!previous || previous.state === current.state) return;
    if (current.state !== "blocked" && current.state !== "done") return;
    if (current.state === "done" && session.launch?.parentSessionId) return;

    const throttleKey = `${session.id}:${current.state}`;
    const now = this.now();
    const last = this.lastProgramPushAt.get(throttleKey);
    if (last !== undefined && now - last < PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) return;

    if (
      this.deliver(session.id, this.programStatusContent(change, session), { skipPresent: true })
    ) {
      // Entries older than the interval no longer throttle anything; keep the map bounded.
      for (const [key, at] of this.lastProgramPushAt) {
        if (now - at >= PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) this.lastProgramPushAt.delete(key);
      }
      this.lastProgramPushAt.set(throttleKey, now);
    }
  }

  /**
   * Bodies carry what the user needs to act: the question with its choices, the approval
   * request from program status, or the first part of the agent's last message. Pushes are end-to-end encrypted
   * (protocol/push/spec.md), and the phone swaps in the fixed text while App Lock or a scoped
   * lock covers the session.
   */
  private programStatusContent(change: ProgramStatusSync, session: Session): PushEventContent {
    const { current } = change;
    if (current.state === "blocked") {
      const kind = current.kind ?? "question";
      const fixed = BLOCKED_PRESENTATION[kind];
      const detail =
        clip(change.blockedDetail, BODY_DETAIL_MAX) ?? clip(current.message, BODY_DETAIL_MAX);
      return {
        event: "blocked",
        kind,
        title: fixed.title,
        body: detail ?? fixed.body,
        detailed: detail !== undefined,
      };
    }
    const detail = clip(session.lastMessage, BODY_DETAIL_MAX);
    return {
      event: "done",
      title: "Session Done",
      body: detail ?? "The run finished.",
      detailed: detail !== undefined,
    };
  }

  /** Returns whether a push was attempted (some registered device was not skipped). */
  private deliver(
    sessionId: string,
    content: PushEventContent,
    options: { skipPresent: boolean; skipMirroredTerminal?: boolean },
  ): boolean {
    const registrations = this.push
      .registrations()
      .filter((entry) => !options.skipPresent || !this.options.isDevicePresent(entry.deviceId));
    if (registrations.length === 0) {
      return false;
    }

    const session = this.storage.getSession(sessionId);
    if (options.skipMirroredTerminal && session && sessionEndIsTerminalOwned(session)) return false;
    const workspaceName = session?.workspaceId
      ? clip(this.storage.getWorkspace(session.workspaceId)?.name, TITLE_WORKSPACE_MAX)
      : undefined;
    // A fresh terminal has no name until its title is generated; its first prompt names it.
    const sessionLabel = clip(session?.name, BODY_DETAIL_MAX) ?? clip(session?.firstMessage, 80);
    const { detailed, ...text } = content;
    // Neither which session nor what happened: an anonymous alert says nothing worth a buzz.
    if (!sessionLabel && !detailed) {
      log.info("session_push.skipped_anonymous", { sessionId, pushEvent: content.event });
      return false;
    }
    const notification: PushNotification = {
      ...text,
      title: workspaceName ? `${content.title} · ${workspaceName}` : content.title,
      sessionId,
      ...(session?.workspaceId ? { workspaceId: session.workspaceId } : {}),
      ...(sessionLabel ? { subtitle: sessionLabel } : {}),
    };

    log.info("session_push.sent", {
      sessionId,
      // `event` is the log line's own name in this logger.
      pushEvent: content.event,
      ...(content.kind ? { kind: content.kind } : {}),
      devices: registrations.length,
    });
    for (const registration of registrations) {
      void this.push.send(registration, notification).catch((err: unknown) => {
        log.warn("session_push.send_failed", {
          sessionId,
          event: content.event,
          error: safeErrorMessage(err),
        });
      });
    }
    return true;
  }

  private contentForEvent(payload: SessionBroadcastEvent): PushEventContent | null {
    const { event } = payload;

    switch (event.type) {
      case "session_ended":
        return {
          event: "ended",
          title: "Session Ended",
          body: event.reason || "The session ended.",
          detailed: Boolean(event.reason),
        };
      case "error":
        if (event.error.startsWith("Retrying (")) {
          return null;
        }
        // Error text stays out of pushes, so only the session label can say what this is about.
        return {
          event: "error",
          title: "Session Error",
          body: GENERIC_SESSION_ERROR_REASON,
          detailed: false,
        };
      default:
        return null;
    }
  }
}
