import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export type Json = Record<string, any>;

export type ResumeDecision = "send" | "decline";

export type ResumeBinding = {
  proposal_id: string;
  scope_id: string;
  revision: string | number;
  session?: string;
  ttl_seconds?: number;
};

const TOKEN_VERSION = "v1";
export const DEFAULT_TTL_SECONDS = 300;
const IV_BYTES = 12;
const TAG_BYTES = 16;

const TOKEN_KEY = randomBytes(32);
const spentTokens = new Set<string>();
const pendingByToken = new Map<string, {
  app?: string;
  label?: string;
  pending_text?: string;
  session?: string;
}>();

const SECRET_KEYS = new Set([
  "proposal_id",
  "scope_id",
  "revision",
  "pending_text",
  "receipt",
  "receipts",
  "proposal",
  "ref",
  "binding",
  "session",
  "ttl_seconds",
  "before_revision",
  "after_revision",
]);

export function resetResumeStateForTests(): void {
  spentTokens.clear();
  pendingByToken.clear();
}

export function rememberPending(
  token: string,
  meta: { app?: string; label?: string; pending_text?: string; session?: string },
): void {
  pendingByToken.set(token, meta);
}

export function lookupPending(token: string): {
  app?: string;
  label?: string;
  pending_text?: string;
  session?: string;
} | undefined {
  return pendingByToken.get(token);
}

export function markTokenSpent(token: string): void {
  spentTokens.add(token);
  pendingByToken.delete(token);
}

export function isTokenSpent(token: string): boolean {
  return spentTokens.has(token);
}

function ttlMs(ttlSeconds: number | undefined): number {
  const seconds = typeof ttlSeconds === "number" && Number.isFinite(ttlSeconds) && ttlSeconds > 0
    ? ttlSeconds
    : DEFAULT_TTL_SECONDS;
  return seconds * 1000;
}

export function mintResumeToken(binding: ResumeBinding, now = Date.now()): string {
  const iv = randomBytes(IV_BYTES);
  const payload = Buffer.from(JSON.stringify({
    proposal_id: binding.proposal_id,
    scope_id: binding.scope_id,
    revision: binding.revision,
    session: binding.session ?? null,
    ttl_seconds: typeof binding.ttl_seconds === "number" ? binding.ttl_seconds : DEFAULT_TTL_SECONDS,
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
  if (typeof token !== "string" || token.length === 0) {
    return { ok: false, status: "approval_lost" };
  }
  if (spentTokens.has(token)) {
    return { ok: false, status: "approval_lost" };
  }

  const dot = token.indexOf(".");
  if (dot <= 0) return { ok: false, status: "approval_lost" };
  const version = token.slice(0, dot);
  const packedB64 = token.slice(dot + 1);
  if (version !== TOKEN_VERSION || packedB64.length === 0) {
    return { ok: false, status: "approval_lost" };
  }

  let packed: Buffer;
  try {
    packed = Buffer.from(packedB64, "base64url");
  } catch {
    return { ok: false, status: "approval_lost" };
  }

  if (packed.length <= IV_BYTES + TAG_BYTES) {
    return { ok: false, status: "approval_lost" };
  }

  const iv = packed.subarray(0, IV_BYTES);
  const tag = packed.subarray(packed.length - TAG_BYTES);
  const ciphertext = packed.subarray(IV_BYTES, packed.length - TAG_BYTES);

  let plain: Buffer;
  try {
    const decipher = createDecipheriv("aes-256-gcm", TOKEN_KEY, iv);
    decipher.setAuthTag(tag);
    plain = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  } catch {
    return { ok: false, status: "approval_lost" };
  }

  let parsed: any;
  try {
    parsed = JSON.parse(plain.toString("utf8"));
  } catch {
    return { ok: false, status: "approval_lost" };
  }

  const proposal_id = parsed?.proposal_id;
  const scope_id = parsed?.scope_id;
  const revision = parsed?.revision;
  const iat = parsed?.iat;
  const ttl_seconds = parsed?.ttl_seconds;
  const session = parsed?.session;
  if (
    typeof proposal_id !== "string" || proposal_id.length === 0 ||
    typeof scope_id !== "string" || scope_id.length === 0 ||
    (typeof revision !== "string" && typeof revision !== "number") ||
    (typeof revision === "string" && revision.length === 0) ||
    typeof iat !== "number" || !Number.isFinite(iat)
  ) {
    return { ok: false, status: "approval_lost" };
  }

  const ttl = typeof ttl_seconds === "number" && Number.isFinite(ttl_seconds)
    ? ttl_seconds
    : DEFAULT_TTL_SECONDS;

  if (now - iat > ttlMs(ttl)) {
    return { ok: false, status: "approval_expired" };
  }

  const binding: DecodeOk = {
    proposal_id,
    scope_id,
    revision,
    ttl_seconds: ttl,
    iat,
  };
  if (typeof session === "string" && session.length > 0) binding.session = session;
  return { ok: true, binding };
}

export function startArgv(params: {
  app: string;
  goal: string;
  literals?: Array<{ name: string; value: string }>;
}): string[] {
  const args = ["task", "--app", params.app, "--goal", params.goal, "--json"];
  for (const literal of params.literals ?? []) {
    args.push("--literal", `${literal.name}=${literal.value}`);
  }
  return args;
}

/** Exact JSON line the parked session receives for approve (via CLI pass-through). */
export function approveRequest(binding: ResumeBinding): Json {
  return {
    op: "approve",
    proposal_id: binding.proposal_id,
    scope_id: binding.scope_id,
    revision: binding.revision,
    approve: true,
  };
}

/** Exact JSON line the parked session receives for decline (no approve field). */
export function declineRequest(binding: ResumeBinding): Json {
  return {
    op: "decline",
    proposal_id: binding.proposal_id,
    scope_id: binding.scope_id,
    revision: binding.revision,
  };
}

export function approveArgv(binding: ResumeBinding): string[] {
  if (typeof binding.session !== "string" || binding.session.length === 0) {
    throw new Error("approve requires a parked session name");
  }
  return [
    "approve",
    "--session", binding.session,
    "--proposal-id", String(binding.proposal_id),
    "--scope-id", String(binding.scope_id),
    "--revision", String(binding.revision),
    "--json",
  ];
}

export function declineArgv(binding: ResumeBinding): string[] {
  if (typeof binding.session !== "string" || binding.session.length === 0) {
    throw new Error("decline requires a parked session name");
  }
  return [
    "decline",
    "--session", binding.session,
    "--proposal-id", String(binding.proposal_id),
    "--scope-id", String(binding.scope_id),
    "--revision", String(binding.revision),
    "--json",
  ];
}

export type ParamKind = "start" | "resume" | "invalid_mixed" | "invalid";

export function classifyParams(params: any): ParamKind {
  const hasDecision = params?.decision === "send" || params?.decision === "decline";
  const hasToken = typeof params?.resume_token === "string" && params.resume_token.length > 0;
  const hasGoal = typeof params?.goal === "string";
  const hasApp = typeof params?.app === "string";
  const hasLiterals = params?.literals != null;

  if ((hasDecision || hasToken) && (hasGoal || hasApp || hasLiterals)) return "invalid_mixed";
  if (hasDecision && hasToken) return "resume";
  if (hasGoal && hasApp) return "start";
  return "invalid";
}

export type ResumePlan =
  | { action: "status"; status: "approval_lost" | "approval_expired"; message: string; hint: string }
  | { action: "call"; decision: ResumeDecision; token: string; argv: string[]; request: Json };

export function planResume(
  params: { decision: string; resume_token: string; goal?: unknown; app?: unknown; literals?: unknown },
  now = Date.now(),
): ResumePlan {
  if (classifyParams(params) === "invalid_mixed") {
    return {
      action: "status",
      status: "approval_lost",
      message: "Nothing was sent. A resume call must carry only decision and resume_token.",
      hint: agentHintFor("approval_lost"),
    };
  }

  const decoded = decodeResumeToken(params.resume_token, now);
  if (!decoded.ok) {
    return {
      action: "status",
      status: decoded.status,
      message: decoded.status === "approval_expired"
        ? "Nothing was sent. The approval window expired."
        : "Nothing was sent. Resume is unavailable.",
      hint: agentHintFor(decoded.status),
    };
  }

  if (typeof decoded.binding.session !== "string" || decoded.binding.session.length === 0) {
    return {
      action: "status",
      status: "approval_lost",
      message: "Nothing was sent and resume is unavailable.",
      hint: agentHintFor("approval_lost"),
    };
  }

  const decision = params.decision as ResumeDecision;
  const argv = decision === "send" ? approveArgv(decoded.binding) : declineArgv(decoded.binding);
  const request = decision === "send" ? approveRequest(decoded.binding) : declineRequest(decoded.binding);
  return { action: "call", decision, token: params.resume_token, argv, request };
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
  const source = (value.binding && typeof value.binding === "object") ? value.binding : value;
  const proposal_id = source.proposal_id;
  const scope_id = source.scope_id;
  const revision = source.revision;
  if (
    typeof proposal_id !== "string" || proposal_id.length === 0 ||
    typeof scope_id !== "string" || scope_id.length === 0 ||
    (typeof revision !== "string" && typeof revision !== "number") ||
    (typeof revision === "string" && revision.length === 0)
  ) {
    return null;
  }
  const binding: ResumeBinding = { proposal_id, scope_id, revision };
  if (typeof source.session === "string" && source.session.length > 0) {
    binding.session = source.session;
  }
  if (typeof source.ttl_seconds === "number" && Number.isFinite(source.ttl_seconds)) {
    binding.ttl_seconds = source.ttl_seconds;
  }
  return binding;
}

export type PreparedApproval = {
  agentValue: Json;
  pending_text?: string;
  resume_token?: string;
  failClosed: boolean;
};

/** Read engine binding for approval_required, mint token, strip secrets for the agent. */
export function prepareApprovalRequired(
  value: Json,
  context: { app?: string } = {},
  now = Date.now(),
): PreparedApproval {
  // PR #5 does not expose pending_text; keep exact text only if an engine ever adds it.
  const pending_text = typeof value.pending_text === "string" ? value.pending_text : undefined;
  const binding = readBinding(value);

  if (!binding || typeof binding.session !== "string" || binding.session.length === 0) {
    const agentValue = stripSecrets({ ...value }) as Json;
    agentValue.status = "approval_lost";
    agentValue.message = "Nothing was sent and resume is unavailable.";
    delete agentValue.resume_token;
    return { agentValue, pending_text: undefined, failClosed: true };
  }

  const resume_token = mintResumeToken(binding, now);
  const label = value.pending_action?.label;
  rememberPending(resume_token, {
    app: context.app ?? value.app,
    label: typeof label === "string" ? label : undefined,
    pending_text,
    session: binding.session,
  });

  const agentValue = stripSecrets({ ...value }) as Json;
  agentValue.status = "approval_required";
  agentValue.resume_token = resume_token;
  return { agentValue, pending_text, resume_token, failClosed: false };
}

export function prepareAgentValue(value: Json): Json {
  return stripSecrets({ ...value }) as Json;
}

export function agentHintFor(status: string): string {
  switch (status) {
    case "done":
      return "The task finished and control was released. Summarize only application-level facts supported by evidence.";
    case "approval_required":
      return "Nothing consequential was sent. Explain the pending action in ordinary language from pending_action (operation, role, label, and text source/character count only). Ask the person, then call computer once with only their decision and the resume_token. Do not claim it was sent. A chat yes is not approval; the tool row is.";
    case "declined":
      return "You declined it. Nothing was sent. Do not call computer again for this action.";
    case "approval_lost":
      return "Nothing was sent. Do not retry. Do not rephrase the goal to send the same thing.";
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
    case "not_delivered":
    case "refused":
      return "Control was released. Do not retry automatically or expose Wrangle internals.";
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

export function shouldSpendToken(status: string): boolean {
  return status !== "session_locked";
}

export function statusPayload(
  status: "approval_lost" | "approval_expired" | "declined" | "session_locked" | "delivery_unknown" | "done" | "provider_not_qualified",
  message: string,
  extras: Json = {},
): Json {
  return {
    ok: true,
    value: stripSecrets({ status, message, root_preserved: true, ...extras }) as Json,
    agent_hint: agentHintFor(status),
  };
}

function receiptOf(value: Json): Json | null {
  if (value?.receipt && typeof value.receipt === "object") return value.receipt;
  if (value?.schema === "wrangle.receipt.v1") return value;
  return null;
}

export type MappedResume = {
  status: string;
  message: string;
  evidence?: unknown;
  spend: boolean;
};

/** Map a parked-session CLI reply (or process failure) to an agent-facing outcome. */
export function mapResumeOutcome(input: {
  code: number;
  stdout: string;
  stderr: string;
  reply?: Json | null;
}): MappedResume {
  const combined = `${input.stdout}\n${input.stderr}`;
  if (input.code === 5 && /No wrangle session/i.test(combined)) {
    return {
      status: "approval_expired",
      message: "Nothing was sent. The approval window expired.",
      spend: true,
    };
  }

  const reply = input.reply;
  if (!reply) {
    if (/DeliveryUnknown/i.test(combined)) {
      return {
        status: "delivery_unknown",
        message: "The action may or may not have happened and was not retried.",
        spend: true,
      };
    }
    return {
      status: "approval_lost",
      message: "Nothing was sent. Resume is unavailable.",
      spend: true,
    };
  }

  if (reply.ok === false) {
    if (String(reply.class ?? "") === "DeliveryUnknown" || /DeliveryUnknown/i.test(String(reply.error ?? ""))) {
      return {
        status: "delivery_unknown",
        message: "The action may or may not have happened and was not retried.",
        spend: true,
      };
    }
    if (/No wrangle session/i.test(String(reply.error ?? ""))) {
      return {
        status: "approval_expired",
        message: "Nothing was sent. The approval window expired.",
        spend: true,
      };
    }
    // Unknown failure with ok:false before a durable send: treat as nothing confirmed sent.
    return {
      status: "approval_lost",
      message: "Nothing was sent. Resume is unavailable.",
      spend: true,
    };
  }

  const value = (reply.value ?? {}) as Json;

  if (value.schema === "wrangle.approval.v1") {
    const status = String(value.status ?? "approval_lost");
    if (status === "session_locked") {
      return {
        status: "session_locked",
        message: "Nothing was sent. The Mac is locked.",
        spend: false,
      };
    }
    if (status === "approval_expired") {
      return {
        status: "approval_expired",
        message: "Nothing was sent. The approval window expired.",
        spend: true,
      };
    }
    return {
      status: "approval_lost",
      message: "Nothing was sent. Resume is unavailable.",
      spend: true,
    };
  }

  const receipt = receiptOf(value);
  if (receipt) {
    if (receipt.reason === "declined" || (receipt.dispatch === "refused" && receipt.reason === "declined")) {
      return {
        status: "declined",
        message: "You declined it. Nothing was sent.",
        spend: true,
      };
    }
    if (receipt.dispatch === "delivery_unknown") {
      return {
        status: "delivery_unknown",
        message: "The action may or may not have happened and was not retried.",
        spend: true,
      };
    }
    if (receipt.dispatch === "delivered") {
      return {
        status: "done",
        message: "The requested result is visible in the application.",
        evidence: value.evidence,
        spend: true,
      };
    }
    if (receipt.dispatch === "not_delivered") {
      // Spent proposal / post-marker lock: nothing to retry.
      return {
        status: "approval_lost",
        message: "Nothing was sent. Resume is unavailable.",
        spend: true,
      };
    }
    if (receipt.dispatch === "refused" && receipt.reason === "provider_not_qualified") {
      return {
        status: "provider_not_qualified",
        message: "The decision provider may inspect but is not qualified to change the app.",
        spend: true,
      };
    }
    if (receipt.dispatch === "refused") {
      return {
        status: "approval_lost",
        message: "Nothing was sent. Resume is unavailable.",
        spend: true,
      };
    }
  }

  // Unrecognized success shape after an approve/decline call: fail closed without claiming delivery.
  return {
    status: "delivery_unknown",
    message: "The action may or may not have happened and was not retried.",
    spend: true,
  };
}

export function agentValueFromMapped(mapped: MappedResume): Json {
  const value: Json = {
    status: mapped.status,
    message: mapped.message,
    root_preserved: true,
  };
  if (mapped.evidence != null) value.evidence = stripSecrets(mapped.evidence);
  return value;
}
