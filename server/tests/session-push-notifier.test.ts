import { describe, expect, it, vi } from "vitest";

import type { ProgramStatusSync } from "../src/program-status.js";
import { SessionPushNotifier } from "../src/session-push-notifier.js";
import type { PushNotification, PushSender } from "../src/push/push-sender.js";
import type { SessionBroadcastEvent } from "../src/session-broadcast.js";
import type { Storage } from "../src/storage.js";
import type { ProgramStatus, PushRegistration, Session } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

/** Push registration of paired device "dev-<name>". */
function target(name: string): PushRegistration {
  return {
    deviceId: `dev-${name}`,
    keyId: `kid-${name}`,
    publicKey: "public-key",
    sendToken: `token-${name}`,
    registeredAt: 1,
  };
}

type MockPush = PushSender & {
  send: ReturnType<
    typeof vi.fn<(registration: PushRegistration, notification: PushNotification) => Promise<null>>
  >;
};

/** `devices` is read on every push, so tests can add a registration later. */
function makePush(devices: string[]): MockPush {
  return {
    registrations: vi.fn(() => devices.map(target)),
    send: vi.fn(async () => null),
  } as unknown as MockPush;
}

type MockStorage = Storage & {
  getSession: ReturnType<typeof vi.fn<(id: string) => Session | undefined>>;
};

function makeStorage(
  session: Session | undefined = makeSession(),
  workspaces: Record<string, string> = {},
): MockStorage {
  return {
    getSession: vi.fn((id: string) => (session?.id === id ? session : undefined)),
    getWorkspace: vi.fn((id: string) =>
      workspaces[id] ? { id, name: workspaces[id] } : undefined,
    ),
  } as unknown as MockStorage;
}

function makeNotifier(
  push: PushSender,
  storage: Storage,
  options: { presentDevices?: Iterable<string>; now?: () => number } = {},
) {
  const present = new Set(options.presentDevices ?? []);
  return new SessionPushNotifier(push, storage, {
    isDevicePresent: (deviceId) => present.has(deviceId),
    ...(options.now ? { now: options.now } : {}),
  });
}

function event(
  sessionId: string,
  eventPayload: SessionBroadcastEvent["event"],
): SessionBroadcastEvent {
  return {
    sessionId,
    event: eventPayload,
    durable: true,
  };
}

function change(
  previous: Partial<ProgramStatus> | undefined,
  current: Partial<ProgramStatus>,
): ProgramStatusSync {
  const prev = previous && ({ state: "working", since: 1, ...previous } as ProgramStatus);
  const next = { state: "working", since: 2, ...current } as ProgramStatus;
  return {
    previous: prev,
    current: next,
    changed: !prev || prev.state !== next.state || prev.message !== next.message,
  };
}

describe("SessionPushNotifier", () => {
  it("seals a session-ended alert separately for every registered device", () => {
    const push = makePush(["phone", "ipad"]);
    const storage = makeStorage(makeSession({ name: "Deploy fix" }));
    const notifier = makeNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "completed" }));

    const expected: PushNotification = {
      event: "ended",
      title: "Session Ended",
      body: "completed",
      sessionId: "s1",
      workspaceId: "w1",
      subtitle: "Deploy fix",
    };
    expect(push.send.mock.calls).toEqual([
      [target("phone"), expected],
      [target("ipad"), expected],
    ]);
  });

  it("uses a fixed body when a named session ends without a reason", () => {
    const push = makePush(["phone"]);
    const notifier = makeNotifier(push, makeStorage(makeSession({ name: "Deploy" })));

    notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "" }));

    expect(push.send).toHaveBeenCalledWith(
      target("phone"),
      expect.objectContaining({ body: "The session ended." }),
    );
  });

  it("replaces non-retry error text with a fixed body", () => {
    const push = makePush(["phone"]);
    const notifier = makeNotifier(push, makeStorage(makeSession({ name: "Bug hunt" })));
    const rawError =
      "model crashed while reading /Users/alice/.ssh/id_rsa with bearer token sk_secret";

    notifier.handleSessionEvent(event("s1", { type: "error", error: rawError }));

    expect(push.send).toHaveBeenCalledWith(
      target("phone"),
      expect.objectContaining({
        event: "error",
        title: "Session Error",
        body: "Open Oppi to review the session error.",
      }),
    );
    expect(JSON.stringify(push.send.mock.calls)).not.toContain(rawError);
  });

  it("ignores retry errors without loading the session", () => {
    const push = makePush(["phone"]);
    const storage = makeStorage();
    const notifier = makeNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "error", error: "Retrying (3/5)" }));

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.send).not.toHaveBeenCalled();
  });

  it("sends nothing and loads no session when no device has a push key", () => {
    const push = makePush([]);
    const storage = makeStorage();
    const notifier = makeNotifier(push, storage);

    notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "done" }));

    expect(storage.getSession).not.toHaveBeenCalled();
    expect(push.send).not.toHaveBeenCalled();
  });

  describe("program status pushes", () => {
    it.each([
      ["permission", "Needs Approval", "Waiting for your approval."],
      ["question", "Question", "Waiting for your answer."],
      ["auth", "Sign-in Needed", "Waiting for you to sign in."],
    ] as const)("pushes on entering blocked (%s) with the request text", (kind, title) => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change(
          { state: "working" },
          { state: "blocked", kind, message: "Allow rm -rf /Users/alice/secrets?" },
        ),
      );

      expect(push.send).toHaveBeenCalledWith(target("phone"), {
        event: "blocked",
        kind,
        title,
        body: "Allow rm -rf /Users/alice/secrets?",
        sessionId: "s1",
        workspaceId: "w1",
        subtitle: "Deploy",
      });
    });

    it("names the workspace in the title and falls back to the first prompt for an unnamed session", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ firstMessage: "  fix the\n flaky   login test " });
      const notifier = makeNotifier(push, makeStorage(session, { w1: "Home" }));

      notifier.handleProgramStatusChange(
        session,
        change(
          { state: "working" },
          { state: "blocked", kind: "question", message: "Which branch?" },
        ),
      );

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({
          title: "Question \u00b7 Home",
          subtitle: "fix the flaky login test",
          body: "Which branch?",
        }),
      );
    });

    it("skips session-ended alerts for mirrored terminals", () => {
      const push = makePush(["phone"]);
      const notifier = makeNotifier(push, makeStorage(makeSession({ runtime: "pi-tui" })));

      notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "closed" }));

      expect(push.send).not.toHaveBeenCalled();
    });

    it("treats a blocked status without a kind as a question", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked" }),
      );

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ kind: "question", body: "Waiting for your answer." }),
      );
    });

    it("uses the fixed done body when the session has no last message", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Fix login" });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ title: "Session Done", body: "The run finished." }),
      );
    });

    it("pushes on entering done with the start of the last message", () => {
      const push = makePush(["phone"]);
      const session = makeSession({
        name: "Fix login",
        lastMessage: `Fixed the login test.\n\n${"x".repeat(400)}`,
      });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "done", message: "Fix login" }),
      );

      expect(push.send).toHaveBeenCalledTimes(1);
      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({
          event: "done",
          title: "Session Done",
          subtitle: "Fix login",
          body: `Fixed the login test. ${"x".repeat(217)}\u2026`,
        }),
      );
    });

    it("pushes no done for a delegated session, but still pushes its blocked", () => {
      const push = makePush(["phone"]);
      const child = makeSession({
        id: "child",
        name: "Child task",
        launch: { status: "created", requestedAt: 1, parentSessionId: "parent" },
      });
      const notifier = makeNotifier(push, makeStorage(child));

      notifier.handleProgramStatusChange(child, change({ state: "working" }, { state: "done" }));
      expect(push.send).not.toHaveBeenCalled();

      notifier.handleProgramStatusChange(
        child,
        change({ state: "working" }, { state: "blocked", kind: "permission" }),
      );
      expect(push.send).toHaveBeenCalledTimes(1);
      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ sessionId: "child", event: "blocked" }),
      );
    });

    it("still pushes done for a top-level session that has launch metadata", () => {
      const push = makePush(["phone"]);
      const session = makeSession({
        name: "Deploy",
        launch: { status: "created", requestedAt: 1 },
      });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));

      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("puts the question's choices and remaining count in the body", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, {
        ...change(
          { state: "working" },
          { state: "blocked", kind: "question", message: "Which branch?" },
        ),
        blockedDetail: "Which branch? Options: main, dev (+1 more question)",
      });

      expect(push.send).toHaveBeenCalledWith(
        target("phone"),
        expect.objectContaining({ body: "Which branch? Options: main, dev (+1 more question)" }),
      );
    });

    it("drops anonymous alerts: no session label and only fixed text", () => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));
      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question" }),
      );
      notifier.handleSessionEvent(event("s1", { type: "error", error: "boom" }));
      notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "" }));
      expect(push.send).not.toHaveBeenCalled();

      // Detail alone says what the alert is about, without a session label.
      notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "completed" }));
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it.each(["idle", "working", "error"] as const)("does not push on entering %s", (state) => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(session, change({ state: "done" }, { state }));

      expect(push.send).not.toHaveBeenCalled();
    });

    it("does not push for message-only changes or a first-ever status", () => {
      const push = makePush(["phone"]);
      const session = makeSession();
      const notifier = makeNotifier(push, makeStorage(session));

      notifier.handleProgramStatusChange(
        session,
        change({ state: "done", message: "a" }, { state: "done", message: "b" }),
      );
      notifier.handleProgramStatusChange(session, change(undefined, { state: "done" }));

      expect(push.send).not.toHaveBeenCalled();
    });

    it("skips only devices that are present: an open iPad does not silence the phone", () => {
      const push = makePush(["phone", "ipad"]);
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(session), {
        presentDevices: ["dev-ipad"],
      });

      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: "Which?" }),
      );
      notifier.handleProgramStatusChange(session, change({ state: "working" }, { state: "done" }));

      expect(push.send.mock.calls.map(([sent]) => sent.deviceId)).toEqual([
        "dev-phone",
        "dev-phone",
      ]);
    });

    it("stays silent while the only device is present, and pushes once it leaves", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Deploy" });
      const present = new Set(["dev-phone"]);
      const notifier = new SessionPushNotifier(push, makeStorage(session), {
        isDevicePresent: (deviceId) => present.has(deviceId),
      });
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).not.toHaveBeenCalled();

      // A skipped push starts no throttle: the next transition after leaving still pushes.
      present.clear();
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("keeps sending ended and error alerts while the device is present", () => {
      const push = makePush(["phone"]);
      const notifier = makeNotifier(push, makeStorage(), { presentDevices: ["dev-phone"] });

      notifier.handleSessionEvent(event("s1", { type: "session_ended", reason: "completed" }));

      expect(push.send).toHaveBeenCalledTimes(1);
    });

    it("rate-limits per session and kind, then allows a later transition", () => {
      const push = makePush(["phone"]);
      const session = makeSession({ name: "Deploy" });
      let now = 1_000_000;
      const notifier = makeNotifier(push, makeStorage(session), { now: () => now });
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      now += 10_000;
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).toHaveBeenCalledTimes(1);

      // A different kind, and a different session, are not throttled by that push.
      notifier.handleProgramStatusChange(
        session,
        change({ state: "working" }, { state: "blocked", kind: "question", message: "Q?" }),
      );
      notifier.handleProgramStatusChange(makeSession({ id: "s2", lastMessage: "Done." }), toDone);
      expect(push.send).toHaveBeenCalledTimes(3);

      now += 60_000;
      notifier.handleProgramStatusChange(session, toDone);
      expect(push.send).toHaveBeenCalledTimes(4);
    });

    it("does not start the throttle when no device has a push key", () => {
      const devices: string[] = [];
      const push = makePush(devices);
      const session = makeSession({ name: "Deploy" });
      const notifier = makeNotifier(push, makeStorage(session));
      const toDone = change({ state: "working" }, { state: "done" });

      notifier.handleProgramStatusChange(session, toDone);
      devices.push("phone");
      notifier.handleProgramStatusChange(session, toDone);

      expect(push.send).toHaveBeenCalledTimes(1);
    });
  });
});
