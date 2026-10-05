import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

import {
  agentHintFor,
  agentOutputFromMapped,
  agentValueFromMapped,
  classifyParams,
  decodeResumeToken,
  gateSendApproval,
  lookupPending,
  mapResumeOutcome,
  markTokenSpent,
  planResume,
  prepareAgentValue,
  prepareApprovalRequired,
  resultStatusLabel,
  startArgv,
  statusPayload,
  type Json,
} from "./computer-resume.ts";

const StartParameters = Type.Object({
  goal: Type.String({ minLength: 1, maxLength: 2_000,
    description: "The user's complete natural-language goal, preserving exact quoted text" }),
  app: Type.String({ minLength: 1, maxLength: 200,
    description: "The macOS application name stated by the user, such as Slack or Finder" }),
  literals: Type.Optional(Type.Array(Type.Object({
    name: Type.String({ minLength: 1, maxLength: 80 }),
    value: Type.String({ minLength: 1, maxLength: 2_000,
      description: "Exact non-secret text supplied by the user; never model-generated" }),
  }), { maxItems: 16 })),
});

const ResumeParameters = Type.Object({
  decision: Type.Union([
    Type.Literal("send", { description: "Person confirmed Send on the tool row" }),
    Type.Literal("decline", { description: "Person confirmed Don't send on the tool row" }),
  ]),
  resume_token: Type.String({ minLength: 1, maxLength: 4_000,
    description: "Opaque token from approval_required; never invent or edit it" }),
}, { additionalProperties: false });

const Parameters = Type.Union([StartParameters, ResumeParameters]);

type StartParams = {
  goal: string;
  app: string;
  literals?: Array<{ name: string; value: string }>;
};

type ResumeParams = {
  decision: "send" | "decline";
  resume_token: string;
};

type Params = StartParams | ResumeParams;

function parseResult(stdout: string, stderr: string): Json {
  try {
    return JSON.parse(stdout);
  } catch {
    const diagnostic = stderr.trim() || stdout.trim() || "no diagnostic";
    throw new Error(`Wrangle did not return a usable task result: ${diagnostic}`);
  }
}

function tryParseJson(text: string): Json | null {
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

function replyLooksSessionLocked(reply: Json): boolean {
  const diagnostic = `${reply.error ?? ""} ${reply.class ?? ""} ${reply.value?.status ?? ""}`;
  return /session_locked/i.test(diagnostic);
}

function agentOutput(value: Json, extras: Json = {}) {
  const status = String(value.status ?? "");
  const output = {
    ok: true,
    value,
    agent_hint: agentHintFor(status),
    ...extras,
  };
  return {
    content: [{ type: "text", text: JSON.stringify({ ok: true, value, agent_hint: output.agent_hint }) }],
    details: output,
  };
}

function handleStartValue(value: Json, context: { app?: string } = {}) {
  if (value.status === "approval_required") {
    const prepared = prepareApprovalRequired({ ...value }, { app: context.app });
    if (prepared.failClosed) {
      return agentOutput(prepared.agentValue, { app: context.app });
    }
    return agentOutput(prepared.agentValue, {
      app: context.app ?? prepared.agentValue.app,
      pending_text: prepared.pending_text,
      pending_label: value.pending_action?.label,
      resume_token: prepared.resume_token,
    });
  }

  const agentValue = prepareAgentValue({ ...value });
  return agentOutput(agentValue, { app: context.app ?? agentValue.app });
}

async function runStart(pi: ExtensionAPI, params: StartParams, signal: AbortSignal | undefined, onUpdate: any) {
  onUpdate?.({
    content: [{ type: "text", text: `Working in ${params.app}…` }],
    details: { status: "running", app: params.app },
  });
  const process = await pi.exec("wrangle", startArgv(params), { signal, timeout: 300_000 });
  const reply = parseResult(process.stdout, process.stderr);
  if (reply.ok === false) {
    if (replyLooksSessionLocked(reply)) {
      return agentOutput({
        status: "session_locked",
        message: "Nothing was sent. The Mac is locked.",
        app: params.app,
        root_preserved: true,
      }, { app: params.app });
    }
    throw new Error(failureMessage(reply));
  }
  if (process.code !== 0) {
    throw new Error(`Wrangle stopped unexpectedly: ${process.stderr.trim() || "no diagnostic"}`);
  }
  return handleStartValue(reply.value as Json, { app: params.app });
}

async function runResume(
  pi: ExtensionAPI,
  params: ResumeParams,
  signal: AbortSignal | undefined,
  onUpdate: any,
  ctx: ExtensionContext,
) {
  const pending = lookupPending(params.resume_token);
  const decoded = decodeResumeToken(params.resume_token);
  const pendingText = pending?.pending_text
    ?? (decoded.ok ? decoded.binding.pending_text : undefined);
  const label = pending?.label ? ` (${pending.label})` : "";
  const appBit = pending?.app ? ` in ${pending.app}` : "";
  onUpdate?.({
    content: [{ type: "text", text: params.decision === "send"
      ? `Sending${appBit}${label}…`
      : `Declining${appBit}${label}…` }],
    details: { status: "running", decision: params.decision, app: pending?.app },
  });

  const plan = planResume(params);
  if (plan.action === "status") {
    const payload = statusPayload(plan.status, plan.message);
    return {
      content: [{ type: "text", text: JSON.stringify(payload) }],
      details: payload,
    };
  }

  // decision "send" requires a true tool-row confirm showing the exact pending_text.
  if (plan.decision === "send") {
    const gate = await gateSendApproval({
      pendingText,
      hasUI: Boolean(ctx?.hasUI),
      ui: ctx?.ui,
    });
    if (gate.action === "blocked") {
      const payload = statusPayload(gate.status, gate.message);
      return {
        content: [{ type: "text", text: JSON.stringify(payload) }],
        details: payload,
      };
    }
  }

  let process: { code?: number | null; stdout: string; stderr: string };
  let aborted = false;
  let timedOut = false;
  try {
    process = await pi.exec("wrangle", plan.argv, { signal, timeout: 300_000 });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    aborted = Boolean(signal?.aborted) || /abort/i.test(message);
    timedOut = /timed?\s*out|timeout/i.test(message);
    process = { code: 1, stdout: "", stderr: message };
  }

  const reply = tryParseJson(process.stdout.trim()) ?? tryParseJson(process.stderr.trim());
  const mapped = mapResumeOutcome({
    code: process.code ?? 1,
    stdout: process.stdout,
    stderr: process.stderr,
    reply,
    app: pending?.app,
    aborted,
    timedOut,
  });

  if (mapped.spend) markTokenSpent(plan.token);

  const output = agentOutputFromMapped(mapped);
  return {
    content: [{ type: "text", text: JSON.stringify({ ok: true, value: output.value, agent_hint: output.agent_hint }) }],
    details: {
      ...output,
      app: pending?.app,
      // pending_text stays in details only for person-facing render; strip from agent content above.
      pending_text: pendingText,
    },
  };
}

export default function computer(pi: ExtensionAPI) {
  pi.registerTool({
    name: "computer",
    label: "Computer",
    description: "Complete one natural-language task inside one exact macOS application window. Wrangle selects the window, reads it, makes bounded typed decisions, enforces policy, verifies every action, releases control automatically, and leaves the application window open. Consequential actions pause for a person on the tool row; resume once with only decision and resume_token.",
    promptSnippet: "Complete one scoped macOS application task from a natural goal",
    promptGuidelines: [
      "Call computer exactly once for a macOS application request, passing the complete natural goal and application name. Do not manually list, attach, observe, drill, execute, or finish.",
      "Computer owns the bounded read-decide-act-verify loop and releases the window automatically. Never ask the user for refs, window IDs, proposals, revisions, or Wrangle commands.",
      "Never use shell commands, raw accessibility helpers, or another computer-use tool during or after a computer task, including for debugging.",
      "Pass literals only when they are exact non-secret text from the user's request. Never invent prose, credentials, coordinates, selectors, commands, URLs, or key sequences.",
      "A natural imperative permits necessary reversible navigation. Consequential actions stop before delivery on approval_required. Explain the pending action from pending_action only, ask the person, then call computer once with only decision (send or decline) and resume_token. A chat yes is not approval; the tool row is.",
      "Do not call computer again after declined, approval_lost, approval_expired, or delivery_unknown. session_locked may resume with the same token after the Mac is unlocked. Do not start a new goal to retry the same consequential action.",
      "If computer reports uncertain delivery, never retry. If it reports ambiguity, ask the user to focus the intended window rather than selecting one invisibly.",
      "After computer returns, report application-level outcomes in ordinary language. Do not expose AX terminology, driver names, refs, revisions, proposals, or receipt mechanics unless debugging was requested.",
      "Do not encode site-specific click procedures or skill names. Wrangle applies any matching stored UI skill itself; pass only the natural goal and application name.",
    ],
    parameters: Parameters,
    executionMode: "sequential",

    async execute(_toolCallId, params: Params, signal, onUpdate, ctx: ExtensionContext) {
      const kind = classifyParams(params);
      if (kind === "invalid_mixed") {
        const payload = statusPayload(
          "approval_lost",
          "Nothing was sent. A resume call must carry only decision and resume_token.",
        );
        return {
          content: [{ type: "text", text: JSON.stringify(payload) }],
          details: payload,
        };
      }
      if (kind === "resume") {
        return runResume(pi, params as ResumeParams, signal, onUpdate, ctx);
      }
      if (kind === "start") {
        return runStart(pi, params as StartParams, signal, onUpdate);
      }
      const payload = statusPayload(
        "approval_lost",
        "Nothing was sent. Computer needs either a goal and app, or a decision and resume_token.",
      );
      return {
        content: [{ type: "text", text: JSON.stringify(payload) }],
        details: payload,
      };
    },

    renderCall(args, theme) {
      if (args?.decision === "send") {
        const pending = typeof args.resume_token === "string" ? lookupPending(args.resume_token) : undefined;
        let text = theme.fg("toolTitle", theme.bold("Send"));
        if (pending?.app) text += ` ${theme.fg("dim", pending.app)}`;
        if (pending?.label) text += ` ${theme.fg("dim", String(pending.label).slice(0, 80))}`;
        return new Text(text, 0, 0);
      }
      if (args?.decision === "decline") {
        return new Text(theme.fg("toolTitle", theme.bold("Don't send")), 0, 0);
      }
      let text = theme.fg("toolTitle", theme.bold(`Use ${args.app}`));
      if (args.goal) text += ` ${theme.fg("dim", String(args.goal).slice(0, 100))}`;
      return new Text(text, 0, 0);
    },

    renderResult(result, { isPartial }, theme) {
      if (isPartial) return new Text(theme.fg("warning", "Working…"), 0, 0);
      const details = result.details as Json | undefined;
      if (!details?.value && details?.ok !== true) {
        return new Text(theme.fg("error", "Wrangle did not return a result"), 0, 0);
      }
      const value = (details.value ?? {}) as Json;
      if (value.status === "approval_required") {
        const app = details.app ?? value.app ?? "the app";
        const lines = [`Waiting for you in ${app}`];
        // Exact pending_text only — never invent or fall back to a label.
        if (typeof details.pending_text === "string" && details.pending_text.length > 0) {
          lines.push(details.pending_text);
        }
        lines.push("Nothing has been sent.");
        return new Text(theme.fg("warning", lines.join("\n")), 0, 0);
      }
      const status = resultStatusLabel(String(value.status ?? ""));
      const safe = value.status === "done";
      return new Text(theme.fg(safe ? "success" : "warning", status), 0, 0);
    },
  });
}
