import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

import { executeComputer } from "./computer-execute.ts";
import { lookupPending, lookupPersonView, resultStatusLabel, type Json } from "./computer-resume.ts";

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
    Type.Literal("send", { description: "Ask the person to confirm Send in the tool row" }),
    Type.Literal("decline", { description: "The person chose not to send" }),
  ]),
  resume_token: Type.String({ minLength: 1, maxLength: 8_000,
    description: "Opaque token from approval_required; never invent or edit it" }),
}, { additionalProperties: false });

const Parameters = Type.Union([StartParameters, ResumeParameters]);

export default function computer(pi: ExtensionAPI) {
  pi.registerTool({
    name: "computer",
    label: "Computer",
    description: "Complete one natural-language task inside one exact macOS application window. Wrangle selects the window, reads it, makes bounded typed decisions, enforces policy, verifies every action, releases control automatically, and leaves the application window open. Consequential actions pause; resume once with only decision and resume_token, and the person confirms Send in the tool row.",
    promptSnippet: "Complete one scoped macOS application task from a natural goal",
    promptGuidelines: [
      "Call computer exactly once for a macOS application request, passing the complete natural goal and application name. Do not manually list, attach, observe, drill, execute, or finish.",
      "Computer owns the bounded read-decide-act-verify loop and releases the window automatically. Never ask the user for refs, window IDs, proposals, revisions, or Wrangle commands.",
      "Never use shell commands, raw accessibility helpers, or another computer-use tool during or after a computer task, including for debugging.",
      "Pass literals only when they are exact non-secret text from the user's request. Never invent prose, credentials, coordinates, selectors, commands, URLs, or key sequences.",
      "A natural imperative permits necessary reversible navigation. Consequential actions stop before delivery on approval_required. Explain the pending action from pending_action only, then call computer once with only decision (send or decline) and resume_token. With send, the person confirms in the tool row; a chat yes is not approval.",
      "Do not call computer again after declined, approval_lost, approval_expired, or delivery_unknown. session_locked may resume with the same token after the Mac is unlocked. Do not start a new goal to retry the same consequential action.",
      "If computer reports uncertain delivery, never retry. If it reports ambiguity, ask the user to focus the intended window rather than selecting one invisibly.",
      "After computer returns, report application-level outcomes in ordinary language. Do not expose AX terminology, driver names, refs, revisions, proposals, or receipt mechanics unless debugging was requested.",
      "Do not encode site-specific click procedures or skill names. Wrangle applies any matching stored UI skill itself; pass only the natural goal and application name.",
    ],
    parameters: Parameters,
    executionMode: "sequential",

    async execute(toolCallId, params, signal, onUpdate, ctx: ExtensionContext) {
      return executeComputer(pi, toolCallId, params, signal, onUpdate, ctx) as any;
    },

    renderCall(args: any, theme) {
      if (args?.decision === "send") {
        const pending = typeof args.resume_token === "string" ? lookupPending(args.resume_token) : undefined;
        let text = theme.fg("toolTitle", theme.bold("Send"));
        if (pending?.app) text += ` ${theme.fg("dim", pending.app)}`;
        if (pending?.label) text += ` ${theme.fg("dim", String(pending.label).slice(0, 80))}`;
        return new Text(text, 0, 0);
      }
      if (args?.decision === "decline") return new Text(theme.fg("toolTitle", theme.bold("Don't send")), 0, 0);
      let text = theme.fg("toolTitle", theme.bold(`Use ${args.app}`));
      if (args.goal) text += ` ${theme.fg("dim", String(args.goal).slice(0, 100))}`;
      return new Text(text, 0, 0);
    },

    renderResult(result, { isPartial }, theme, context) {
      if (isPartial) return new Text(theme.fg("warning", "Working…"), 0, 0);
      const details = result.details as Json | undefined;
      const status = typeof details?.status === "string" ? details.status : "";
      if (!status) return new Text(theme.fg("error", "Wrangle did not return a result"), 0, 0);
      if (status === "approval_required") {
        // Person-facing only: summary comes from module memory keyed by toolCallId, never from details.
        const view = lookupPersonView(context?.toolCallId);
        const app = view?.app ?? details?.app ?? "the app";
        const lines = [`Waiting for you in ${app}`];
        if (view?.summaryLines?.length) lines.push(...view.summaryLines);
        else lines.push("The exact action can't be shown here, so it can't be sent.");
        lines.push("Nothing has been sent.");
        return new Text(theme.fg("warning", lines.join("\n")), 0, 0);
      }
      return new Text(theme.fg(status === "done" ? "success" : "warning", resultStatusLabel(status)), 0, 0);
    },
  });
}
