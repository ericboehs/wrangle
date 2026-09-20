import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

const Parameters = Type.Object({
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

type Params = {
  goal: string;
  app: string;
  literals?: Array<{ name: string; value: string }>;
};

type Json = Record<string, any>;

function argumentsFor(params: Params): string[] {
  const args = ["task", "--app", params.app, "--goal", params.goal, "--json"];
  for (const literal of params.literals ?? []) args.push("--literal", `${literal.name}=${literal.value}`);
  return args;
}

function parseResult(stdout: string, stderr: string): Json {
  try {
    return JSON.parse(stdout);
  } catch {
    const diagnostic = stderr.trim() || stdout.trim() || "no diagnostic";
    throw new Error(`Wrangle did not return a usable task result: ${diagnostic}`);
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

function agentHint(value: Json): string {
  switch (value.status) {
    case "done":
      return "The task finished and control was released. Summarize only application-level facts supported by evidence.";
    case "approval_required":
      return "Nothing consequential was sent. Explain the pending application-level action and that this alpha cannot resume its bound approval; do not call computer again or claim completion.";
    case "provider_not_qualified":
      return "No change was made. The configured provider is assessment-only; explain that limitation plainly.";
    case "delivery_unknown":
      return "The action may or may not have happened. Never repeat it. Explain the uncertainty plainly.";
    case "blocked":
    case "handoff":
    case "low_confidence":
    case "budget_exhausted":
      return "Control was released. Explain the practical blocker from the result without exposing AX, refs, revisions, or receipts.";
    default:
      return "Control was released. Do not retry automatically or expose Wrangle internals.";
  }
}

function resultStatus(value: Json): string {
  switch (value.status) {
    case "done": return "Done";
    case "approval_required": return "Approval needed; no consequential action sent";
    case "provider_not_qualified": return "Assessment only; no change made";
    case "delivery_unknown": return "Stopped: result uncertain";
    case "blocked": return "Blocked safely";
    case "handoff": return "Needs user input";
    case "low_confidence": return "Paused safely";
    case "budget_exhausted": return "Stopped at task limit";
    case "not_delivered":
    case "refused": return "No change made";
    default: return "Stopped safely";
  }
}

export default function computer(pi: ExtensionAPI) {
  pi.registerTool({
    name: "computer",
    label: "Computer",
    description: "Complete one natural-language task inside one exact macOS application window. Wrangle selects the window, reads it, makes bounded typed decisions, enforces policy, verifies every action, releases control automatically, and leaves the application window open.",
    promptSnippet: "Complete one scoped macOS application task from a natural goal",
    promptGuidelines: [
      "Call computer exactly once for a macOS application request, passing the complete natural goal and application name. Do not manually list, attach, observe, drill, execute, or finish.",
      "Computer owns the bounded read-decide-act-verify loop and releases the window automatically. Never ask the user for refs, window IDs, proposals, revisions, or Wrangle commands.",
      "Never use shell commands, raw accessibility helpers, or another computer-use tool during or after a computer task, including for debugging.",
      "Pass literals only when they are exact non-secret text from the user's request. Never invent prose, credentials, coordinates, selectors, commands, URLs, or key sequences.",
      "A natural imperative permits necessary reversible navigation. Consequential actions stop before delivery; this alpha cannot resume the bound proposal, so explain that limitation and do not loop.",
      "If computer reports uncertain delivery, never retry. If it reports ambiguity, ask the user to focus the intended window rather than selecting one invisibly.",
      "After computer returns, report application-level outcomes in ordinary language. Do not expose AX terminology, driver names, refs, revisions, proposals, or receipt mechanics unless debugging was requested.",
    ],
    parameters: Parameters,
    executionMode: "sequential",

    async execute(_toolCallId, params: Params, signal, onUpdate) {
      onUpdate?.({
        content: [{ type: "text", text: `Working in ${params.app}…` }],
        details: { status: "running", app: params.app },
      });
      const process = await pi.exec("wrangle", argumentsFor(params), { signal, timeout: 300_000 });
      const reply = parseResult(process.stdout, process.stderr);
      if (reply.ok === false) throw new Error(failureMessage(reply));
      if (process.code !== 0) {
        throw new Error(`Wrangle stopped unexpectedly: ${process.stderr.trim() || "no diagnostic"}`);
      }

      const value = reply.value as Json;
      const output = { ok: true, value, agent_hint: agentHint(value) };
      return { content: [{ type: "text", text: JSON.stringify(output) }], details: output };
    },

    renderCall(args, theme) {
      let text = theme.fg("toolTitle", theme.bold(`Use ${args.app}`));
      if (args.goal) text += ` ${theme.fg("dim", args.goal.slice(0, 100))}`;
      return new Text(text, 0, 0);
    },

    renderResult(result, { isPartial }, theme) {
      if (isPartial) return new Text(theme.fg("warning", "Working…"), 0, 0);
      const details = result.details as Json | undefined;
      if (!details?.value) return new Text(theme.fg("error", "Wrangle did not return a result"), 0, 0);
      const value = details.value as Json;
      const status = resultStatus(value);
      const safe = value.status === "done";
      return new Text(theme.fg(safe ? "success" : "warning", status), 0, 0);
    },
  });
}
