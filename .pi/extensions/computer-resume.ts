import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export type Json = Record<string, any>;

export type ResumeDecision = "send" | "decline";

export type ResumeIds = {
  proposal_id: string;
  scope_id: string;
  revision: string | number;
};

const TOKEN_VERSION = "v1";
export const RESUME_TTL_MS = 300_000;
const IV_BYTES = 12;
const TAG_BYTES = 16;

const TOKEN_KEY = randomBytes(32);
const spentTokens = new Set<string>();
const pendingByToken = new Map<string, { app?: string; label?: string; pending_text?: string }>();

const SECRET_KEYS = new Set([
  "proposal_id",
  "scope_id",
  "revision",
  "pending_text",
  "receipt",
  "receipts",
  "proposal",
  "ref",
]);

export function resetResumeStateForTests(): void {
  spentTokens.clear();
  pendingByToken.clear();
}

export function rememberPending(
  token: string,
  meta: { app?: string; label?: string; pending_text?: string },
): void {
  pendingByToken.set(token, meta);
}

export function lookupPending(token: string): { app?: string; label?: string; pending_text?: string } | undefined {
  return pendingByToken.get(token);
}

export function markTokenSpent(token: string): void {
  spentTokens.add(token);
  pendingByToken.delete(token);
}

export function isTokenSpent(token: string): boolean {
  return spentTokens.has(token);
}

export function mintResumeToken(ids: ResumeIds, now = Date.now()): string {
  const iv = randomBytes(IV_BYTES);
  const payload = Buffer.from(JSON.stringify({
    proposal_id: ids.proposal_id,
    scope_id: ids.scope_id,
    revision: ids.revision,
    iat: now,
  }), "utf8");
  const cipher = createCipheriv("aes-256-gcm", TOKEN_KEY, iv);
  const ciphertext = Buffer.concat([cipher.update(payload), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `${TOKEN_VERSION}.${Buffer.concat([iv, ciphertext, tag]).toString("base64url")}`;
}

export type DecodeOk = ResumeIds & { iat: number };
export type DecodeResult =
  | { ok: true; ids: DecodeOk }
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
  if (
    typeof proposal_id !== "string" || proposal_id.length === 0 ||
    typeof scope_id !== "string" || scope_id.length === 0 ||
    (typeof revision !== "string" && typeof revision !== "number") ||
    (typeof revision === "string" && revision.length === 0) ||
    typeof iat !== "number" || !Number.isFinite(iat)
  ) {
    return { ok: false, status: "approval_lost" };
  }

  if (now - iat > RESUME_TTL_MS) {
    return { ok: false, status: "approval_expired" };
  }

  return { ok: true, ids: { proposal_id, scope_id, revision, iat } };
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

export function approveArgv(ids: ResumeIds): string[] {
  return [
    "task", "--json", "--op", "approve", "--approve", "true",
    "--proposal-id", String(ids.proposal_id),
    "--scope-id", String(ids.scope_id),
    "--revision", String(ids.revision),
  ];
}

export function declineArgv(ids: ResumeIds): string[] {
  return [
    "task", "--json", "--op", "decline",
    "--proposal-id", String(ids.proposal_id),
    "--scope-id", String(ids.scope_id),
    "--revision", String(ids.revision),
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
  | { action: "call"; decision: ResumeDecision; token: string; argv: string[] };

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

  const decision = params.decision as ResumeDecision;
  const argv = decision === "send" ? approveArgv(decoded.ids) : declineArgv(decoded.ids);
  return { action: "call", decision, token: params.resume_token, argv };
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

export function engineImpliesApprovalLost(value: Json): boolean {
  const status = String(value.status ?? "");
  const diagnostic = `${value.error ?? ""} ${value.message ?? ""} ${status}`;
  return /unknown|already consumed|consumed proposal|proposal.*(unknown|consumed)/i.test(diagnostic);
}

export function mapEngineStatus(value: Json): string {
  if (engineImpliesApprovalLost(value)) return "approval_lost";
  return String(value.status ?? "");
}

export type PreparedApproval = {
  agentValue: Json;
  pending_text?: string;
  resume_token?: string;
  failClosed: boolean;
};

/** Read engine fields for approval_required, mint token, strip secrets for the agent. */
export function prepareApprovalRequired(
  value: Json,
  context: { app?: string } = {},
  now = Date.now(),
): PreparedApproval {
  const pending_text = typeof value.pending_text === "string" ? value.pending_text : undefined;
  const proposal_id = value.proposal_id;
  const scope_id = value.scope_id;
  const revision = value.revision;

  const missing =
    typeof proposal_id !== "string" || proposal_id.length === 0 ||
    typeof scope_id !== "string" || scope_id.length === 0 ||
    (typeof revision !== "string" && typeof revision !== "number") ||
    (typeof revision === "string" && revision.length === 0);

  if (missing) {
    const agentValue = stripSecrets({ ...value }) as Json;
    agentValue.status = "approval_lost";
    agentValue.message = "Nothing was sent and resume is unavailable.";
    delete agentValue.resume_token;
    return { agentValue, pending_text: undefined, failClosed: true };
  }

  const resume_token = mintResumeToken(
    { proposal_id, scope_id, revision },
    now,
  );
  const label = value.pending_action?.label;
  rememberPending(resume_token, {
    app: context.app ?? value.app,
    label: typeof label === "string" ? label : undefined,
    pending_text,
  });

  const agentValue = stripSecrets({ ...value }) as Json;
  agentValue.status = "approval_required";
  agentValue.resume_token = resume_token;
  return { agentValue, pending_text, resume_token, failClosed: false };
}

export function prepareAgentValue(value: Json): Json {
  const mapped = { ...value, status: mapEngineStatus(value) };
  return stripSecrets(mapped) as Json;
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
  status: "approval_lost" | "approval_expired" | "declined" | "session_locked",
  message: string,
): Json {
  return {
    ok: true,
    value: { status, message, root_preserved: true },
    agent_hint: agentHintFor(status),
  };
}
