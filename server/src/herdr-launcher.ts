import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { promisify } from "node:util";

import { localApiSocketPath } from "./local-api-socket.js";
import { safeErrorMessage } from "./log-utils.js";
import type { SessionRuntimes } from "./runtime-router.js";
import {
  SessionLifecycleError,
  type CreateWorkspaceSessionResult,
  type SessionLifecycleService,
} from "./session-lifecycle-service.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";
import { MAIN_WORKTREE_ID } from "./worktrees.js";

const execute = promisify(execFile);
type CreateParams = Parameters<SessionLifecycleService["createWorkspaceSession"]>[0];
type Run = (args: string[]) => Promise<string>;

function quote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function parseCreation(raw: string): { tabId: string; paneId: string } {
  const reply: unknown = JSON.parse(raw);
  if (typeof reply === "object" && reply !== null && "result" in reply) {
    const result = reply.result;
    if (typeof result === "object" && result !== null && "tab" in result && "root_pane" in result) {
      const tab = result.tab;
      const pane = result.root_pane;
      if (
        typeof tab === "object" &&
        tab !== null &&
        "tab_id" in tab &&
        typeof tab.tab_id === "string" &&
        typeof pane === "object" &&
        pane !== null &&
        "pane_id" in pane &&
        typeof pane.pane_id === "string"
      )
        return { tabId: tab.tab_id, paneId: pane.pane_id };
    }
  }
  throw new SessionLifecycleError("Herdr returned an invalid tab creation response", 502);
}

/** One launcher per route dispatcher; keyed requests share their entire launch. */
export class HerdrLauncher {
  private readonly pending = new Map<string, Promise<CreateWorkspaceSessionResult | undefined>>();

  constructor(
    private readonly storage: Pick<
      Storage,
      | "getConfig"
      | "getDataDir"
      | "getSession"
      | "saveSession"
      | "findSessionByLaunchIdempotencyKey"
    >,
    private readonly runtimes: Pick<
      SessionRuntimes,
      "waitForLaunchedSession" | "sendPrompt" | "isSessionConnected"
    >,
    private readonly run: Run = async (args) =>
      (await execute("herdr", args, { timeout: 10_000, maxBuffer: 1024 * 1024 })).stdout,
  ) {}

  async createSession(params: CreateParams): Promise<CreateWorkspaceSessionResult | undefined> {
    const launcher = this.storage.getConfig().newSessionLauncher;
    // These are explicitly managed-runtime features, not ordinary phone sessions.
    if (
      !launcher ||
      params.workspace.runtime === "sandbox" ||
      params.engine === "durable" ||
      params.ephemeral ||
      // The route always normalizes an omitted worktree to MAIN_WORKTREE_ID.
      (params.worktreeId !== undefined && params.worktreeId !== MAIN_WORKTREE_ID) ||
      params.parentSessionId ||
      params.autoStop
    )
      return undefined;
    const key = params.idempotencyKey?.trim();
    if (key) {
      const pending = this.pending.get(key);
      if (pending) {
        const result = await pending;
        return result ? { ...result, launchKind: "existing" } : undefined;
      }
      const existing = this.storage.findSessionByLaunchIdempotencyKey(key);
      if (existing) {
        if (existing.workspaceId !== params.workspace.id) {
          throw new SessionLifecycleError("Launch key belongs to another workspace", 409);
        }
        if (existing.launch?.status === "launching") {
          throw new SessionLifecycleError("launch_in_progress", 409);
        }
        if (existing.launch?.status === "failed") {
          throw new SessionLifecycleError(
            existing.launch.promptError ?? "Terminal launch failed",
            502,
          );
        }
        return {
          session: existing,
          createdSession: existing,
          launchKind: "existing",
          ...(params.prompt?.trim()
            ? { prompted: existing.launch?.promptDispatch === "delivered" }
            : {}),
        };
      }
    }
    const launch = this.launch(params, launcher.command);
    if (key) this.pending.set(key, launch);
    try {
      return await launch;
    } finally {
      if (key) this.pending.delete(key);
    }
  }

  private async launch(
    params: CreateParams,
    command: string,
  ): Promise<CreateWorkspaceSessionResult | undefined> {
    // Read-only availability probe: never starts Herdr or writes a session on fallback.
    try {
      await this.run(["workspace", "list"]);
    } catch {
      return undefined;
    }
    const now = Date.now();
    const cwd = homedir();
    const session: Session = {
      id: randomUUID(),
      workspaceId: params.workspace.id,
      runtime: "pi-tui",
      name: params.name?.trim() || params.workspace.name,
      status: "starting",
      createdAt: now,
      lastActivity: now,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      launch: {
        source: "workspace-wrapper",
        status: "launching",
        requestedAt: now,
        idempotencyKey: params.idempotencyKey?.trim(),
        target: { workspaceId: params.workspace.id, runtime: "host", displayCwd: cwd },
        ...(params.model ? { model: params.model, modelPolicy: "required" } : {}),
        thinkingLevel: params.thinking,
        tools: { allowed: params.tools, excluded: params.excludeTools, noTools: params.noTools },
        promptDispatch: "not_sent",
      },
    };
    this.storage.saveSession(session);
    const controller = new AbortController();
    const timer = setTimeout(
      () =>
        controller.abort(
          new SessionLifecycleError(
            `Timed out waiting 60 seconds for omo mirror ${session.id}; inspect the new Herdr tab`,
            504,
          ),
        ),
      60_000,
    );
    const registered = this.runtimes.waitForLaunchedSession(session.id, controller.signal);
    // CLI failure and timeout can race; attach a rejection handler immediately.
    void registered.catch(() => undefined);
    let tabId: string | undefined;
    let connectedSession: Session | undefined;
    try {
      const created = parseCreation(
        await this.run([
          "tab",
          "create",
          "--cwd",
          cwd,
          "--label",
          session.name ?? "omo",
          "--no-focus",
          "--env",
          `OPPI_MIRROR_SOCKET=${localApiSocketPath(this.storage.getDataDir())}`,
          "--env",
          "OPPI_MIRROR_AUTO_START=true",
        ]),
      );
      tabId = created.tabId;
      const args = [command, "--session-id", session.id, "--name", session.name ?? "omo"];
      if (params.model) args.push("--model", params.model, "--no-model-fallback");
      if (params.thinking) args.push("--thinking", params.thinking);
      if (params.tools) args.push("--tools", params.tools.join(","));
      if (params.excludeTools) args.push("--exclude-tools", params.excludeTools.join(","));
      if (params.noTools) args.push(params.noTools === "all" ? "--no-tools" : "--no-builtin-tools");
      // pane run takes shell text, not argv. Quote every value, including names.
      await this.run(["pane", "run", created.paneId, `exec ${args.map(quote).join(" ")}`]);
      const connected = await registered;
      connectedSession = connected;
      if (!this.runtimes.isSessionConnected(connected.id)) {
        throw new SessionLifecycleError("omo mirror disconnected during launch", 502);
      }
      // Mutate the runtime-owned object, not a detached SQLite read: subsequent
      // mirror events persist this same object.
      const current = connected;
      current.launch = {
        ...session.launch,
        status: "accepted",
        requestedAt: now,
        completedAt: Date.now(),
      };
      this.storage.saveSession(current);
      const createdSession = structuredClone(current);
      if (params.prompt?.trim()) {
        await this.runtimes.sendPrompt(current.id, params.prompt, {
          attachments: params.attachments,
          timestamp: Date.now(),
        });
        current.launch.promptDispatch = "delivered";
        this.storage.saveSession(current);
      }
      return {
        session: current,
        createdSession,
        launchKind: "created",
        ...(params.prompt?.trim() ? { prompted: true, summarySession: current } : {}),
      };
    } catch (error) {
      controller.abort(error);
      const current = connectedSession ?? this.storage.getSession(session.id) ?? session;
      current.launch = {
        ...session.launch,
        status: "failed",
        requestedAt: now,
        completedAt: Date.now(),
        promptError: safeErrorMessage(error),
      };
      if (!this.runtimes.isSessionConnected(session.id)) current.status = "error";
      this.storage.saveSession(current);
      if (error instanceof SessionLifecycleError) throw error;
      throw new SessionLifecycleError(
        `Could not launch omo in Herdr${tabId ? ` tab ${tabId}` : ""}: ${safeErrorMessage(error)}`,
        502,
      );
    } finally {
      clearTimeout(timer);
      controller.abort(new Error("Terminal launch finished"));
    }
  }
}
