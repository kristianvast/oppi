import { homedir } from "node:os";
import { afterEach, describe, expect, it, vi } from "vitest";

import { HerdrLauncher } from "../src/herdr-launcher.js";
import { SessionLifecycleError } from "../src/session-lifecycle-service.js";
import type { ServerConfig, Session, Workspace } from "../src/types.js";

const workspace: Workspace = { id: "home", name: "Home", runtime: "host", hostMount: homedir() };

function fixture(
  options: {
    enabled?: boolean;
    unavailable?: boolean;
    register?: boolean;
    failRun?: boolean;
    failPrompt?: boolean;
  } = {},
) {
  const config: ServerConfig = {
    port: 17749,
    host: "127.0.0.1",
    dataDir: "/tmp/oppi-herdr-test",
    sessionIdleTimeoutMs: 0,
    workspaceIdleTimeoutMs: 0,
    maxSessionsPerWorkspace: 100,
    maxSessionsGlobal: 200,
    ...(options.enabled === false
      ? {}
      : {
          newSessionLauncher: { kind: "herdr-omo", command: "/path with spaces/omo" },
        }),
  };
  const sessions = new Map<string, Session>();
  const storage = {
    getConfig: () => config,
    getDataDir: () => config.dataDir,
    getSession: (id: string) => sessions.get(id),
    saveSession: (session: Session) => {
      sessions.set(session.id, session);
    },
    findSessionByLaunchIdempotencyKey: (key: string) =>
      Array.from(sessions.values()).find((session) => session.launch?.idempotencyKey === key),
  };
  let connected = false;
  let registration: { id: string; resolve: (session: Session) => void } | undefined;
  const waitForLaunchedSession = vi.fn(
    (id: string, signal: AbortSignal) =>
      new Promise<Session>((resolve, reject) => {
        registration = { id, resolve };
        signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      }),
  );
  const sendPrompt = vi.fn(async () => {
    if (options.failPrompt) throw new Error("prompt rejected");
  });
  const runtimes = { waitForLaunchedSession, sendPrompt, isSessionConnected: () => connected };
  const run = vi.fn(async (args: string[]) => {
    if (args[0] === "workspace") {
      if (options.unavailable) throw new Error("Herdr is not running");
      return JSON.stringify({ result: { workspaces: [{ workspace_id: "w4" }] } });
    }
    if (args[0] === "tab") {
      return JSON.stringify({
        result: { tab: { tab_id: "w4:t9" }, root_pane: { pane_id: "w4:p9" } },
      });
    }
    if (options.failRun) throw new Error("pane run failed");
    if (registration && options.register !== false) {
      const session = sessions.get(registration.id);
      if (!session) throw new Error("Missing reserved session");
      connected = true;
      session.status = "ready";
      // Registration deliberately beats the pane-run acknowledgement.
      registration.resolve(session);
    }
    return "";
  });
  return {
    launcher: new HerdrLauncher(storage, runtimes, run),
    run,
    sendPrompt,
    waitForLaunchedSession,
    sessions,
  };
}

afterEach(() => vi.useRealTimers());

describe("HerdrLauncher", () => {
  it("leaves the managed path untouched when disabled", async () => {
    const { launcher, run, sessions } = fixture({ enabled: false });
    expect(await launcher.createSession({ workspace })).toBeUndefined();
    expect(run).not.toHaveBeenCalled();
    expect(sessions.size).toBe(0);
  });

  it("falls back without creating a row when Herdr is unavailable", async () => {
    const { launcher, run, sessions } = fixture({ unavailable: true });
    expect(await launcher.createSession({ workspace })).toBeUndefined();
    expect(run).toHaveBeenCalledTimes(1);
    expect(sessions.size).toBe(0);
  });

  it("treats the route's default main worktree as an ordinary terminal launch", async () => {
    const { launcher, run } = fixture({ unavailable: true });
    expect(await launcher.createSession({ workspace, worktreeId: "main" })).toBeUndefined();
    expect(run).toHaveBeenCalledTimes(1);
  });

  it.each([
    { workspace: { ...workspace, runtime: "sandbox" as const } },
    { workspace, engine: "durable" as const },
    { workspace, ephemeral: true },
    { workspace, worktreeId: "worktree-1" },
    { workspace, parentSessionId: "parent-1" },
    { workspace, autoStop: true },
  ])("keeps explicitly managed launch features on their owner path: %j", async (params) => {
    const { launcher, run } = fixture();
    expect(await launcher.createSession(params)).toBeUndefined();
    expect(run).not.toHaveBeenCalled();
  });

  it("returns the correlated mirror even when registration beats pane acknowledgement", async () => {
    const { launcher, run, waitForLaunchedSession, sendPrompt } = fixture();
    const result = await launcher.createSession({
      workspace,
      name: "owner's $(touch /tmp/no)",
      model: "provider/model",
      thinking: "high",
      tools: ["read"],
      excludeTools: ["bash"],
      noTools: "builtin",
    });
    expect(result?.session).toMatchObject({
      runtime: "pi-tui",
      status: "ready",
      workspaceId: "home",
    });
    expect(waitForLaunchedSession).toHaveBeenCalledWith(
      result?.session.id,
      expect.any(AbortSignal),
    );
    expect(run.mock.calls[1]?.[0]).toEqual([
      "tab",
      "create",
      "--cwd",
      homedir(),
      "--label",
      "owner's $(touch /tmp/no)",
      "--no-focus",
      "--env",
      "OPPI_MIRROR_SOCKET=/tmp/oppi-herdr-test/run/oppi.sock",
      "--env",
      "OPPI_MIRROR_AUTO_START=true",
    ]);
    expect(run.mock.calls[2]?.[0]).toEqual([
      "pane",
      "run",
      "w4:p9",
      `exec '/path with spaces/omo' '--session-id' '${result?.session.id}' '--name' 'owner'\\''s $(touch /tmp/no)' '--model' 'provider/model' '--no-model-fallback' '--thinking' 'high' '--tools' 'read' '--exclude-tools' 'bash' '--no-builtin-tools'`,
    ]);
    expect(sendPrompt).not.toHaveBeenCalled();
  });

  it("dispatches the initial prompt through the connected mirror exactly once", async () => {
    const { launcher, run, sendPrompt } = fixture();
    const params = { workspace, prompt: "first prompt", idempotencyKey: "launch-1" };
    const [first, duplicate] = await Promise.all([
      launcher.createSession(params),
      launcher.createSession(params),
    ]);
    const replay = await launcher.createSession(params);
    expect(first?.session.id).toBe(duplicate?.session.id);
    expect(replay?.session.id).toBe(first?.session.id);
    expect(duplicate?.launchKind).toBe("existing");
    expect(replay?.launchKind).toBe("existing");
    expect(first?.prompted).toBe(true);
    expect(run).toHaveBeenCalledTimes(3);
    expect(sendPrompt).toHaveBeenCalledExactlyOnceWith(first?.session.id, "first prompt", {
      attachments: undefined,
      timestamp: expect.any(Number),
    });
  });

  it("does not start a headless duplicate after pane run fails", async () => {
    const { launcher, sessions } = fixture({ failRun: true });
    await expect(launcher.createSession({ workspace })).rejects.toMatchObject({ statusCode: 502 });
    expect(Array.from(sessions.values())[0]).toMatchObject({
      status: "error",
      launch: { status: "failed", promptDispatch: "not_sent" },
    });
  });

  it("reports a bounded registration timeout and leaves inspectable failure evidence", async () => {
    vi.useFakeTimers();
    const { launcher, sessions, waitForLaunchedSession } = fixture({ register: false });
    const launch = launcher.createSession({ workspace });
    const assertion = expect(launch).rejects.toMatchObject({ statusCode: 504 });
    await vi.advanceTimersByTimeAsync(60_000);
    await assertion;
    expect(waitForLaunchedSession.mock.calls[0]?.[1].aborted).toBe(true);
    expect(Array.from(sessions.values())[0]?.launch?.status).toBe("failed");
    expect(vi.getTimerCount()).toBe(0);
  });

  it("retains the connected mirror when the initial prompt is rejected", async () => {
    const { launcher, sessions } = fixture({ failPrompt: true });
    await expect(launcher.createSession({ workspace, prompt: "first" })).rejects.toBeInstanceOf(
      SessionLifecycleError,
    );
    expect(Array.from(sessions.values())[0]).toMatchObject({
      status: "ready",
      launch: { status: "failed", promptDispatch: "not_sent" },
    });
  });
});
