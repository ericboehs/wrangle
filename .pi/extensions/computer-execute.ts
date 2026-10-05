import {
  agentHintFor,
  agentOutputFromMapped,
  cancelledOutcome,
  classifyParams,
  lookupPending,
  mapResumeOutcome,
  markTokenSpent,
  noSummaryOutcome,
  noUiOutcome,
  planResume,
  prepareAgentValue,
  prepareApprovalRequired,
  rememberPersonView,
  startArgv,
  summaryLines,
  type Json,
  type MappedResume,
} from "./computer-resume.ts";

/** Structural subset of Pi's ExtensionAPI.exec (dist/core/exec.d.ts ExecResult). */
export type ExecLike = {
  exec(command: string, args: string[], options?: { signal?: AbortSignal; timeout?: number }):
    Promise<{ stdout: string; stderr: string; code: number; killed?: boolean }>;
};

/** Structural subset of Pi's ExtensionContext (hasUI, ui.confirm(title, message, { signal, timeout })). */
export type ContextLike = {
  hasUI?: boolean;
  ui?: {
    confirm?: (title: string, message: string, opts?: { signal?: AbortSignal; timeout?: number }) => Promise<boolean>;
  } | null;
} | undefined;

export type StartParams = { goal: string; app: string; literals?: Array<{ name: string; value: string }> };
export type ResumeParams = { decision: "send" | "decline"; resume_token: string };

const EXEC_TIMEOUT_MS = 300_000;

function parseJson(text: string): Json | null {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function failureMessage(result: Json): string {
  const diagnostic = String(result.error ?? "Wrangle could not use the application window");
  if (diagnostic.includes("session_locked")) {
    return "The Mac is locked. Ask the user to unlock it, then stop; do not try another automation path.";
  }
  if (diagnostic.includes("decision provider") || diagnostic.includes("JEV_API_KEY") ||
      diagnostic.includes("WRANGLE_DESKTOP_PROVIDER")) {
    return "Wrangle's typed decision provider is not configured. Stop without using shell commands or another computer-use tool.";
  }
  if (result.class === "ScopeBusy") {
    return "Another Wrangle task is using that window. Stop rather than bypassing its exclusive scope.";
  }
  if (diagnostic.includes("More than one")) {
    return `${diagnostic}. Ask the user to focus the intended window, then retry the same natural task.`;
  }
  return `Wrangle could not complete the task: ${diagnostic}. Do not debug with shell commands or substitute another tool.`;
}

/**
 * Tool result. `content` is what the model sees (and Pi persists it). `details` is persisted too,
 * so it carries only status and app; person-facing text lives in module memory keyed by toolCallId.
 */
function result(agentPayload: Json, app?: string) {
  const status = String(agentPayload.value?.status ?? "");
  return {
    content: [{ type: "text" as const, text: JSON.stringify(agentPayload) }],
    details: { status, app },
  };
}

function mappedResult(mapped: MappedResume, app?: string) {
  return result(agentOutputFromMapped(mapped), app);
}

async function runStart(pi: ExecLike, toolCallId: string, params: StartParams, signal: AbortSignal | undefined, onUpdate: any) {
  onUpdate?.({ content: [{ type: "text", text: `Working in ${params.app}…` }], details: { status: "running", app: params.app } });
  const process = await pi.exec("wrangle", startArgv(params), { signal, timeout: EXEC_TIMEOUT_MS });
  const reply = parseJson(process.stdout);
  if (!reply) {
    throw new Error(`Wrangle did not return a usable task result: ${process.stderr.trim() || process.stdout.trim() || "no diagnostic"}`);
  }
  if (reply.ok === false) {
    if (/session_locked/.test(`${reply.error ?? ""} ${reply.class ?? ""}`)) {
      return result({
        ok: true,
        value: { status: "session_locked", message: "Nothing was sent. The Mac is locked.", root_preserved: true },
        agent_hint: agentHintFor("session_locked"),
      }, params.app);
    }
    throw new Error(failureMessage(reply));
  }
  if (process.code !== 0) throw new Error(`Wrangle stopped unexpectedly: ${process.stderr.trim() || "no diagnostic"}`);

  const value = (reply.value ?? {}) as Json;
  if (value.status === "approval_required") {
    const prepared = prepareApprovalRequired(value, { app: params.app });
    rememberPersonView(toolCallId, prepared.person);
    const status = String(prepared.agentValue.status);
    return result({ ok: true, value: prepared.agentValue, agent_hint: agentHintFor(status) }, prepared.person.app ?? params.app);
  }
  const agentValue = prepareAgentValue(value);
  return result({ ok: true, value: agentValue, agent_hint: agentHintFor(String(agentValue.status ?? "")) }, params.app);
}

async function callEngine(
  pi: ExecLike,
  decision: "send" | "decline",
  argv: string[],
  signal: AbortSignal | undefined,
  app: string | undefined,
): Promise<MappedResume> {
  let process: { stdout: string; stderr: string; code: number; killed?: boolean };
  try {
    process = await pi.exec("wrangle", argv, { signal, timeout: EXEC_TIMEOUT_MS });
  } catch (error) {
    // exec itself failed mid-call: delivery state is unknown for approve; conservative for decline too.
    return mapResumeOutcome({ decision, code: 1, stdout: "", stderr: String(error), killed: true, app });
  }
  return mapResumeOutcome({
    decision,
    code: process.code,
    stdout: process.stdout,
    stderr: process.stderr,
    killed: Boolean(process.killed),
    reply: parseJson(process.stdout.trim()),
    app,
  });
}

async function runResume(
  pi: ExecLike,
  params: ResumeParams,
  signal: AbortSignal | undefined,
  onUpdate: any,
  ctx: ContextLike,
) {
  const pending = lookupPending(params.resume_token);
  const plan = planResume(params);
  if (plan.action === "status") return mappedResult(plan.mapped, pending?.app);

  const app = plan.binding.pending_summary?.app ?? pending?.app;

  if (plan.decision === "decline") {
    onUpdate?.({ content: [{ type: "text", text: "Not sending…" }], details: { status: "running", app } });
    const mapped = await callEngine(pi, "decline", plan.argv, signal, app);
    if (mapped.spend) markTokenSpent(plan.token);
    return mappedResult(mapped, app);
  }

  // decision "send": the person confirms in the tool row. Only a true confirm reaches approve.
  const confirm = ctx?.ui?.confirm;
  if (!ctx?.hasUI || typeof confirm !== "function") return mappedResult(noUiOutcome(), app);

  const view = summaryLines(plan.binding.pending_summary, plan.binding.pending_text);
  if (!view.ok) return mappedResult(noSummaryOutcome(), app);

  const confirmed = await confirm.call(ctx!.ui, view.title, view.message, { signal });
  if (signal?.aborted) return mappedResult(cancelledOutcome(), app);

  if (!confirmed) {
    // The person said no: spend the proposal through the engine decline, which releases the lease.
    onUpdate?.({ content: [{ type: "text", text: "Not sending…" }], details: { status: "running", app } });
    const mapped = await callEngine(pi, "decline", plan.declineArgv, signal, app);
    if (mapped.spend) markTokenSpent(plan.token);
    return mappedResult(mapped, app);
  }

  onUpdate?.({ content: [{ type: "text", text: `Sending in ${app ?? "the app"}…` }], details: { status: "running", app } });
  const mapped = await callEngine(pi, "send", plan.argv, signal, app);
  if (mapped.spend) markTokenSpent(plan.token);
  return mappedResult(mapped, app);
}

/** The whole body of the Pi tool's execute(); computer.ts delegates here so it can be tested without Pi. */
export async function executeComputer(
  pi: ExecLike,
  toolCallId: string,
  params: any,
  signal: AbortSignal | undefined,
  onUpdate: any,
  ctx: ContextLike,
) {
  const kind = classifyParams(params);
  if (kind === "resume") return runResume(pi, params as ResumeParams, signal, onUpdate, ctx);
  if (kind === "start") return runStart(pi, toolCallId, params as StartParams, signal, onUpdate);
  const message = kind === "invalid_mixed"
    ? "Nothing was sent. A resume call must carry only decision and resume_token."
    : "Nothing was sent. Computer needs either a goal and app, or a decision and resume_token.";
  return result({
    ok: true,
    value: { status: "approval_lost", message, root_preserved: true },
    agent_hint: agentHintFor("approval_lost_refused"),
  });
}
