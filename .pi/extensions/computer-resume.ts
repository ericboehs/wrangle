import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export type Json = Record<string, any>;

export type ResumeDecision = "send" | "decline";

/** Tool-only summary Backend attaches to every consequential binding (contract; not yet in PR #5). */
export type PendingSummary = {
  app: string;
  operation: string;
  role: string;
  label: string;
  typed_text?: string;
};

export type ResumeBinding = {
  proposal_id: string;
  scope_id: string;
  revision: string | number;
  session?: string;
  ttl_seconds?: number;
  pending_text?: string;
  pending_summary?: PendingSummary;
};

const TOKEN_VERSION = "v1";
export const DEFAULT_TTL_SECONDS = 300;
const IV_BYTES = 12;
const TAG_BYTES = 16;

/** Effect value Backend's DesktopEffect uses for a verified, applied postcondition. */
export const VERIFIED_EFFECT = "verified";

const TOKEN_KEY = randomBytes(32);
const spentTokens = new Set<string>();

type PendingMeta = { app?: string; label?: string };
const pendingByToken = new Map<string, PendingMeta>();

/** Person-facing view, keyed by toolCallId. Module memory only; never written to tool details. */
export type PersonView = {
  app?: string;
  summaryLines?: string[];
  sendable?: boolean;
};
const personViews = new Map<string, PersonView>();

const SECRET_KEYS = new Set([
  "proposal_id",
  "scope_id",
  "revision",
  "pending_text",
  "pending_summary",
  "typed_text",
  "receipt",
  "receipts",
  "proposal",
  "ref",
  "binding",
  "session",
  "ttl_seconds",
  "before_revision",
  "after_revision",
  "verification_error",
  "decider",
  "decision",
  "confidence",
  "provider",
  "model",
]);

export function resetResumeStateForTests(): void {
  spentTokens.clear();
  pendingByToken.clear();
  personViews.clear();
}

export function rememberPending(token: string, meta: PendingMeta): void {
  pendingByToken.set(token, meta);
}

export function lookupPending(token: string): PendingMeta | undefined {
  return pendingByToken.get(token);
}

export function rememberPersonView(toolCallId: string, view: PersonView): void {
  if (toolCallId) personViews.set(toolCallId, view);
}

export function lookupPersonView(toolCallId: string | undefined): PersonView | undefined {
  return toolCallId ? personViews.get(toolCallId) : undefined;
}

export function markTokenSpent(token: string): void {
  spentTokens.add(token);
  pendingByToken.delete(token);
}

export function isTokenSpent(token: string): boolean {
  return spentTokens.has(token);
}

function nonEmpty(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function validRevision(value: unknown): value is string | number {
  return (typeof value === "number" && Number.isFinite(value)) || nonEmpty(value);
}

export function readPendingSummary(value: unknown): PendingSummary | undefined {
  if (!value || typeof value !== "object") return undefined;
  const source = value as Json;
  if (!nonEmpty(source.app) || !nonEmpty(source.operation)) return undefined;
  if (typeof source.role !== "string" || typeof source.label !== "string") return undefined;
  const summary: PendingSummary = {
    app: source.app,
    operation: source.operation,
    role: source.role,
    label: source.label,
  };
  if (nonEmpty(source.typed_text)) summary.typed_text = source.typed_text;
  return summary;
}

export function mintResumeToken(binding: ResumeBinding, now = Date.now()): string {
  const iv = randomBytes(IV_BYTES);
  const payload = Buffer.from(JSON.stringify({
    proposal_id: binding.proposal_id,
    scope_id: binding.scope_id,
    revision: binding.revision,
    session: binding.session ?? null,
    ttl_seconds: typeof binding.ttl_seconds === "number" ? binding.ttl_seconds : DEFAULT_TTL_SECONDS,
    pending_text: nonEmpty(binding.pending_text) ? binding.pending_text : null,
    pending_summary: binding.pending_summary ?? null,
    iat: now,
  }), "utf8");
  const cipher = createCipheriv("aes-256-gcm", TOKEN_KEY, iv);
  const ciphertext = Buffer.concat([cipher.update(payload), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${TOKEN_VERSION}.${Buffer.concat([iv, ciphertext, tag]).toString("base64url")}`;
}

export type DecodeOk = ResumeBinding & { iat: number; ttl_seconds: number };
export type DecodeResult =
  | { ok: true; binding: DecodeOk }
  | { ok: false; status: "approval_lost" | "approval_expired" };

export function decodeResumeToken(token: string, now = Date.now()): DecodeResult {
  if (!nonEmpty(token) || spentTokens.has(token)) return { ok: false, status: "approval_lost" };

  const dot = token.indexOf(".");
  if (dot <= 0) return { ok: false, status: "approval_lost" };
  if (token.slice(0, dot) !== TOKEN_VERSION) return { ok: false, status: "approval_lost" };
  const packed = Buffer.from(token.slice(dot + 1), "base64url");
  if (packed.length <= IV_BYTES + TAG_BYTES) return { ok: false, status: "approval_lost" };

  let parsed: any;
  try {
    const decipher = createDecipheriv("aes-256-gcm", TOKEN_KEY, packed.subarray(0, IV_BYTES));
    decipher.setAuthTag(packed.subarray(packed.length - TAG_BYTES));
    const plain = Buffer.concat([
      decipher.update(packed.subarray(IV_BYTES, packed.length - TAG_BYTES)),
      decipher.final(),
    ]);
    parsed = JSON.parse(plain.toString("utf8"));
  } catch {
    return { ok: false, status: "approval_lost" };
  }

  if (!nonEmpty(parsed?.proposal_id) || !nonEmpty(parsed?.scope_id) || !validRevision(parsed?.revision) ||
      typeof parsed?.iat !== "number" || !Number.isFinite(parsed.iat)) {
    return { ok: false, status: "approval_lost" };
  }

  const ttl = typeof parsed.ttl_seconds === "number" && Number.isFinite(parsed.ttl_seconds) && parsed.ttl_seconds > 0
    ? parsed.ttl_seconds
    : DEFAULT_TTL_SECONDS;
  if (now - parsed.iat > ttl * 1000) return { ok: false, status: "approval_expired" };

  const binding: DecodeOk = {
    proposal_id: parsed.proposal_id,
    scope_id: parsed.scope_id,
    revision: parsed.revision,
    ttl_seconds: ttl,
    iat: parsed.iat,
  };
  if (nonEmpty(parsed.session)) binding.session = parsed.session;
  if (nonEmpty(parsed.pending_text)) binding.pending_text = parsed.pending_text;
  const summary = readPendingSummary(parsed.pending_summary);
  if (summary) binding.pending_summary = summary;
  return { ok: true, binding };
}

export function startArgv(params: {
  app: string;
  goal: string;
  literals?: Array<{ name: string; value: string }>;
}): string[] {
  const args = ["task", "--app", params.app, "--goal", params.goal, "--json"];
  for (const literal of params.literals ?? []) args.push("--literal", `${literal.name}=${literal.value}`);
  return args;
}

/** JSON line the parked session receives for approve (sent by `wrangle approve`). */
export function approveRequest(binding: ResumeBinding): Json {
  return {
    op: "approve",
    proposal_id: binding.proposal_id,
    scope_id: binding.scope_id,
    revision: binding.revision,
    approve: true,
  };
}

/** JSON line the parked session receives for decline (sent by `wrangle decline`); no approve field. */
export function declineRequest(binding: ResumeBinding): Json {
  return {
    op: "decline",
    proposal_id: binding.proposal_id,
    scope_id: binding.scope_id,
    revision: binding.revision,
  };
}

function bindingArgv(command: "approve" | "decline", binding: ResumeBinding): string[] {
  if (!nonEmpty(binding.session)) throw new Error(`${command} requires a parked session name`);
  return [
    command,
    "--session", binding.session,
    "--proposal-id", String(binding.proposal_id),
    "--scope-id", String(binding.scope_id),
    "--revision", String(binding.revision),
    "--json",
  ];
}

export function approveArgv(binding: ResumeBinding): string[] {
  return bindingArgv("approve", binding);
}

export function declineArgv(binding: ResumeBinding): string[] {
  return bindingArgv("decline", binding);
}

export type ParamKind = "start" | "resume" | "invalid_mixed" | "invalid";

export function classifyParams(params: any): ParamKind {
  const hasDecision = params?.decision === "send" || params?.decision === "decline";
  const hasToken = nonEmpty(params?.resume_token);
  const hasStartField = typeof params?.goal === "string" || typeof params?.app === "string" || params?.literals != null;
  if ((hasDecision || hasToken) && hasStartField) return "invalid_mixed";
  if (hasDecision && hasToken) return "resume";
  if (typeof params?.goal === "string" && typeof params?.app === "string") return "start";
  return "invalid";
}

export type ResumePlan =
  | { action: "status"; mapped: MappedResume }
  | {
      action: "call";
      decision: ResumeDecision;
      token: string;
      binding: DecodeOk;
      argv: string[];
      request: Json;
      declineArgv: string[];
    };

export function planResume(
  params: { decision: string; resume_token: string; goal?: unknown; app?: unknown; literals?: unknown },
  now = Date.now(),
): ResumePlan {
  if (classifyParams(params) === "invalid_mixed") {
    return { action: "status", mapped: lost("Nothing was sent. A resume call must carry only decision and resume_token.", false, "approval_lost_refused") };
  }
  const decoded = decodeResumeToken(params.resume_token, now);
  if (!decoded.ok) {
    return {
      action: "status",
      mapped: decoded.status === "approval_expired"
        ? expired()
        : lost("Nothing was sent. Resume is unavailable.", false),
    };
  }
  if (!nonEmpty(decoded.binding.session)) {
    return { action: "status", mapped: lost("Nothing was sent and resume is unavailable.", false) };
  }
  const decision = params.decision as ResumeDecision;
  return {
    action: "call",
    decision,
    token: params.resume_token,
    binding: decoded.binding,
    argv: decision === "send" ? approveArgv(decoded.binding) : declineArgv(decoded.binding),
    request: decision === "send" ? approveRequest(decoded.binding) : declineRequest(decoded.binding),
    declineArgv: declineArgv(decoded.binding),
  };
}

export function stripSecrets(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stripSecrets);
  if (value && typeof value === "object") {
    const out: Json = {};
    for (const [key, child] of Object.entries(value as Json)) {
      if (SECRET_KEYS.has(key)) continue;
      out[key] = stripSecrets(child);
    }
    return out;
  }
  return value;
}

function readBinding(value: Json): ResumeBinding | null {
  const source = value.binding && typeof value.binding === "object" ? value.binding as Json : null;
  if (!source) return null;
  if (!nonEmpty(source.proposal_id) || !nonEmpty(source.scope_id) || !validRevision(source.revision)) return null;
  const binding: ResumeBinding = {
    proposal_id: source.proposal_id,
    scope_id: source.scope_id,
    revision: source.revision,
  };
  if (nonEmpty(source.session)) binding.session = source.session;
  if (typeof source.ttl_seconds === "number" && Number.isFinite(source.ttl_seconds)) binding.ttl_seconds = source.ttl_seconds;
  if (nonEmpty(source.pending_text)) binding.pending_text = source.pending_text;
  const summary = readPendingSummary(source.pending_summary);
  if (summary) binding.pending_summary = summary;
  return binding;
}

export type ConfirmPlan =
  | { ok: true; title: string; message: string; lines: string[] }
  | { ok: false; reason: "missing_summary" | "missing_text" };

/** Person-facing lines: app, operation, role, label, and the exact text that will be typed. */
export function summaryLines(summary: PendingSummary | undefined, pendingText: string | undefined): ConfirmPlan {
  if (!summary) return { ok: false, reason: "missing_summary" };
  const text = nonEmpty(pendingText) ? pendingText : summary.typed_text;
  if (summary.operation === "SET_TEXT" && !nonEmpty(text)) return { ok: false, reason: "missing_text" };
  const target = [summary.role, summary.label ? `"${summary.label}"` : ""].filter(Boolean).join(" ");
  const lines = [`${summary.app}: ${summary.operation}${target ? ` ${target}` : ""}`];
  if (nonEmpty(text)) lines.push(`Text: ${text}`);
  return { ok: true, title: `Send in ${summary.app}?`, message: lines.join("\n"), lines };
}

export type PreparedApproval = {
  agentValue: Json;
  resume_token?: string;
  person: PersonView;
  failClosed: boolean;
};

/** Read the engine binding on approval_required, mint the token, strip secrets for the agent. */
export function prepareApprovalRequired(
  value: Json,
  context: { app?: string } = {},
  now = Date.now(),
): PreparedApproval {
  const binding = readBinding(value);
  const app = context.app ?? (typeof value.app === "string" ? value.app : undefined);

  if (!binding || !nonEmpty(binding.session)) {
    const agentValue = stripSecrets({ ...value }) as Json;
    agentValue.status = "approval_lost";
    agentValue.message = "Nothing was sent and resume is unavailable.";
    return { agentValue, person: { app }, failClosed: true };
  }

  const resume_token = mintResumeToken(binding, now);
  const label = binding.pending_summary?.label ?? value.pending_action?.label;
  rememberPending(resume_token, { app: binding.pending_summary?.app ?? app, label: typeof label === "string" ? label : undefined });

  const plan = summaryLines(binding.pending_summary, binding.pending_text);
  const person: PersonView = {
    app: binding.pending_summary?.app ?? app,
    summaryLines: plan.ok ? plan.lines : undefined,
    sendable: plan.ok,
  };

  const agentValue = stripSecrets({ ...value }) as Json;
  agentValue.status = "approval_required";
  agentValue.resume_token = resume_token;
  return { agentValue, resume_token, person, failClosed: false };
}

export function prepareAgentValue(value: Json): Json {
  return stripSecrets({ ...value }) as Json;
}

export function agentHintFor(key: string): string {
  switch (key) {
    case "done":
      return "The task finished and control was released. Summarize only application-level facts supported by evidence.";
    case "done_unverified":
      return "The action was sent, but Wrangle could not verify the result. Do not claim the result is visible. Do not repeat it.";
    case "approval_required":
      return "Nothing consequential was sent. Explain the pending action in ordinary language from pending_action (operation, role, label, and text source/character count only). Ask the person, then call computer once with only their decision and the resume_token. The person confirms Send in the tool row. Do not claim it was sent. A chat yes is not approval.";
    case "declined":
      return "The person declined it. Nothing was sent. Do not call computer again for this action.";
    case "approval_lost":
      return "Nothing was sent. Do not retry. Do not rephrase the goal to send the same thing.";
    case "approval_lost_refused":
      return "Nothing was sent. Wrangle refused this request. Do not retry on your own; tell the person what happened.";
    case "approval_lost_no_ui":
      return "Nothing was sent. Approval can't happen in this mode because there is no interactive tool row. Do not retry on your own.";
    case "approval_lost_no_summary":
      return "Nothing was sent. The pending action can't be shown to the person for confirmation, so it can't be sent. Do not retry on your own.";
    case "approval_lost_cancelled":
      return "Nothing was sent. The confirmation was interrupted. Do not retry on your own.";
    case "approval_expired":
      return "Nothing was sent. Do not retry.";
    case "delivery_unknown":
      return "The action may or may not have happened. Never repeat it. Explain the uncertainty plainly.";
    case "session_locked":
      return "Nothing was sent. The Mac is locked; ask the user to unlock, then resume with the same token. Do not start a new goal.";
    case "provider_not_qualified":
      return "No change was made. The configured provider is assessment-only; explain that limitation plainly.";
    case "blocked":
    case "handoff":
    case "low_confidence":
    case "budget_exhausted":
      return "Control was released. Explain the practical blocker from the result without exposing AX, refs, revisions, or receipts.";
    default:
      return "Control was released. Do not retry automatically or expose Wrangle internals.";
  }
}

export function resultStatusLabel(status: string): string {
  switch (status) {
    case "done": return "Done";
    case "approval_required": return "Waiting for you";
    case "declined": return "Declined; nothing sent";
    case "approval_lost": return "Approval lost; nothing sent";
    case "approval_expired": return "Approval expired; nothing sent";
    case "session_locked": return "Mac locked; nothing sent";
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

export type MappedResume = {
  status: string;
  message: string;
  evidence?: unknown;
  spend: boolean;
  verified?: boolean;
  hintKey?: string;
};

function lost(message: string, spend: boolean, hintKey = "approval_lost"): MappedResume {
  return { status: "approval_lost", message, spend, hintKey };
}

function expired(): MappedResume {
  return { status: "approval_expired", message: "Nothing was sent. The approval window expired.", spend: true };
}

function unknownDelivery(): MappedResume {
  return { status: "delivery_unknown", message: "The action may or may not have happened and was not retried.", spend: true };
}

export function noUiOutcome(): MappedResume {
  return lost("Nothing was sent. Approval can't happen in this mode.", false, "approval_lost_no_ui");
}

export function noSummaryOutcome(): MappedResume {
  return lost("Nothing was sent. The pending action can't be shown for confirmation.", false, "approval_lost_no_summary");
}

export function cancelledOutcome(): MappedResume {
  return lost("Nothing was sent. The confirmation was interrupted.", false, "approval_lost_cancelled");
}

/** Exact PR #5 SessionClient messages (lib/wrangle/session_server.rb). */
const CLOSED_WITHOUT_REPLY = /The wrangle session closed without replying/;
const NO_WRANGLE_SESSION = /No wrangle session at /;

function receiptOf(value: Json): Json | null {
  if (value?.receipt && typeof value.receipt === "object") return value.receipt;
  if (value?.schema === "wrangle.receipt.v1") return value;
  return null;
}

/** Map a parked-session CLI result to an agent-facing outcome. */
export function mapResumeOutcome(input: {
  decision: ResumeDecision;
  code: number;
  stdout: string;
  stderr: string;
  killed?: boolean;
  aborted?: boolean;
  reply?: Json | null;
  app?: string;
}): MappedResume {
  const combined = `${input.stdout}\n${input.stderr}`;

  // Lost mid-call: timeout/abort kill, or the parked child died after the request was written.
  if (input.killed || input.aborted || CLOSED_WITHOUT_REPLY.test(combined)) return unknownDelivery();

  // No parked child at connect time (exit 5): nothing was sent.
  if (input.code === 5 && NO_WRANGLE_SESSION.test(combined)) return expired();

  const reply = input.reply;
  if (!reply || typeof reply !== "object") {
    if (/DeliveryUnknown/.test(combined)) return unknownDelivery();
    // Unreadable reply: a decline cannot send; an approve might have.
    return input.decision === "decline" ? lost("Nothing was sent. Resume is unavailable.", true) : unknownDelivery();
  }

  if (reply.ok === false) {
    const klass = String(reply.class ?? "");
    const error = String(reply.error ?? "");
    if (klass === "DeliveryUnknown") return unknownDelivery();
    if (klass === "DriverRefusal" && reply.terminal === true) return unknownDelivery();
    if (CLOSED_WITHOUT_REPLY.test(error)) return unknownDelivery();
    if (NO_WRANGLE_SESSION.test(error)) return expired();
    // Request refusal rejected before the binding is consulted: the proposal stays parked.
    if (klass === "ArgumentError") return lost("Nothing was sent. Wrangle refused the request.", false, "approval_lost_refused");
    return lost("Nothing was sent. Resume is unavailable.", true);
  }

  const value = (reply.value ?? {}) as Json;

  if (value.schema === "wrangle.approval.v1") {
    const status = String(value.status ?? "");
    const reason = String(value.reason ?? "");
    if (status === "session_locked") {
      return { status: "session_locked", message: "Nothing was sent. The Mac is locked.", spend: false };
    }
    if (status === "approval_expired") return expired();
    // unknown id / mismatched binding: non-terminal on the engine side; the real approval is still parked.
    if (reason === "unknown") return lost("Nothing was sent. Wrangle refused the request.", false, "approval_lost_refused");
    return lost("Nothing was sent. Resume is unavailable.", true);
  }

  const receipt = receiptOf(value);
  if (receipt) {
    if (receipt.reason === "declined") {
      return { status: "declined", message: "You declined it. Nothing was sent.", spend: true };
    }
    if (receipt.dispatch === "delivery_unknown") return unknownDelivery();
    if (receipt.dispatch === "delivered") {
      const verified = receipt.effect === VERIFIED_EFFECT && !nonEmpty(receipt.verification_error);
      if (!verified) {
        return {
          status: "done",
          message: `Sent, but Wrangle couldn't verify the result in ${input.app ?? "the app"}.`,
          evidence: value.evidence,
          spend: true,
          verified: false,
          hintKey: "done_unverified",
        };
      }
      return {
        status: "done",
        message: "The requested result is visible in the application.",
        evidence: value.evidence,
        spend: true,
        verified: true,
      };
    }
    if (receipt.dispatch === "refused" && receipt.reason === "provider_not_qualified") {
      return {
        status: "provider_not_qualified",
        message: "The decision provider may inspect but is not qualified to change the app.",
        spend: true,
      };
    }
    if (receipt.dispatch === "not_delivered" || receipt.dispatch === "refused") {
      return lost("Nothing was sent. Resume is unavailable.", true);
    }
  }

  return input.decision === "decline" ? lost("Nothing was sent. Resume is unavailable.", true) : unknownDelivery();
}

export function agentOutputFromMapped(mapped: MappedResume): Json {
  const value: Json = { status: mapped.status, message: mapped.message, root_preserved: true };
  if (mapped.evidence != null) value.evidence = stripSecrets(mapped.evidence);
  return { ok: true, value, agent_hint: agentHintFor(mapped.hintKey ?? mapped.status) };
}
