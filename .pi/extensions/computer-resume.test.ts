import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import {
  DEFAULT_TTL_SECONDS,
  VERIFIED_EFFECT,
  agentHintFor,
  agentOutputFromMapped,
  approveArgv,
  approveRequest,
  classifyParams,
  declineArgv,
  declineRequest,
  decodeResumeToken,
  isTokenSpent,
  mapResumeOutcome,
  markTokenSpent,
  mintResumeToken,
  planResume,
  prepareAgentValue,
  prepareApprovalRequired,
  resetResumeStateForTests,
  stripSecrets,
  summaryLines,
} from "./computer-resume.ts";

const SUMMARY = { app: "Slack", operation: "PRESS", role: "button", label: "Send" };
const BINDING = {
  proposal_id: "prop-UNIQUE-aaa111",
  scope_id: "scope-UNIQUE-bbb222",
  revision: "rev-UNIQUE-ccc333",
  session: "task-UNIQUE-ddd444",
  ttl_seconds: 300,
  pending_summary: SUMMARY,
};

const ok = (value: unknown) => ({ ok: true, value });
const map = (decision: "send" | "decline", reply: any, extra: any = {}) =>
  mapResumeOutcome({ decision, code: 0, stdout: "", stderr: "", reply, app: "Slack", ...extra });

beforeEach(() => resetResumeStateForTests());

describe("resume token", () => {
  it("roundtrips ids, session, and pending_summary and hides them", () => {
    const token = mintResumeToken({ ...BINDING, pending_summary: { ...SUMMARY, typed_text: "hi-UNIQUE" } }, 1_700_000_000_000);
    for (const secret of [BINDING.proposal_id, BINDING.scope_id, BINDING.revision, BINDING.session, "hi-UNIQUE", "Slack"]) {
      assert.equal(token.includes(secret), false, secret);
    }
    const decoded = decodeResumeToken(token, 1_700_000_000_000);
    assert.equal(decoded.ok, true);
    if (!decoded.ok) return;
    assert.equal(decoded.binding.proposal_id, BINDING.proposal_id);
    assert.equal(decoded.binding.session, BINDING.session);
    assert.deepEqual(decoded.binding.pending_summary, { ...SUMMARY, typed_text: "hi-UNIQUE" });
  });

  it("garbage, tamper, spent → approval_lost; over ttl → approval_expired; default ttl 300", () => {
    const iat = 1_700_000_000_000;
    const token = mintResumeToken(BINDING, iat);
    assert.deepEqual(decodeResumeToken(`${token.slice(0, -2)}ab`, iat), { ok: false, status: "approval_lost" });
    assert.deepEqual(decodeResumeToken("garbage"), { ok: false, status: "approval_lost" });
    assert.deepEqual(decodeResumeToken(token, iat + 300_001), { ok: false, status: "approval_expired" });
    const noTtl = mintResumeToken({ ...BINDING, ttl_seconds: undefined }, iat);
    const decoded = decodeResumeToken(noTtl, iat);
    assert.equal(decoded.ok && decoded.binding.ttl_seconds, DEFAULT_TTL_SECONDS);
    markTokenSpent(token);
    assert.deepEqual(decodeResumeToken(token, iat), { ok: false, status: "approval_lost" });
  });
});

describe("confirm summary", () => {
  it("shows app, operation, role, label for a click without pending_text", () => {
    const plan = summaryLines(SUMMARY, undefined);
    assert.equal(plan.ok, true);
    if (!plan.ok) return;
    assert.equal(plan.message, 'Slack: PRESS button "Send"');
  });

  it("adds typed_text when present", () => {
    const plan = summaryLines({ ...SUMMARY, typed_text: "hello" }, undefined);
    assert.equal(plan.ok && plan.message, 'Slack: PRESS button "Send"\nText: hello');
  });

  it("SET_TEXT shows exact pending_text, and fails closed without any text", () => {
    const setText = { app: "Slack", operation: "SET_TEXT", role: "textfield", label: "Message" };
    const plan = summaryLines(setText, 'Exactly  "this"\n');
    assert.equal(plan.ok && plan.message, 'Slack: SET_TEXT textfield "Message"\nText: Exactly  "this"\n');
    assert.deepEqual(summaryLines(setText, undefined), { ok: false, reason: "missing_text" });
  });

  it("fails closed only when pending_summary is missing", () => {
    assert.deepEqual(summaryLines(undefined, "text"), { ok: false, reason: "missing_summary" });
  });
});

describe("agent JSON", () => {
  it("approval_required has resume_token and nothing secret, decider stripped", () => {
    const prepared = prepareApprovalRequired({
      status: "approval_required",
      app: "Slack",
      binding: { ...BINDING, pending_text: "typed-UNIQUE", pending_summary: { ...SUMMARY, typed_text: "typed-UNIQUE" } },
      pending_action: { operation: "PRESS", role: "button", label: "Send", text: { source: "goal:1", characters: 12 } },
      decider: { operation: "PRESS", confidence: 0.91, provider: "jev", model: "m-UNIQUE" },
      decision: { operation: "PRESS", confidence: 0.91, provider: "jev", model: "m-UNIQUE" },
      receipt: { dispatch: "held" },
    });
    assert.equal(prepared.failClosed, false);
    const agent = prepared.agentValue;
    assert.equal(agent.status, "approval_required");
    assert.equal(typeof agent.resume_token, "string");
    const content = JSON.stringify(agent);
    for (const key of ["proposal_id", "scope_id", "revision", "session", "ttl_seconds", "binding", "pending_text",
      "pending_summary", "typed_text", "receipt", "decider", "decision", "confidence", "provider", "model"]) {
      assert.equal(content.includes(`"${key}"`), false, key);
    }
    for (const secret of [BINDING.proposal_id, BINDING.scope_id, BINDING.revision, BINDING.session, "typed-UNIQUE", "m-UNIQUE"]) {
      assert.equal(content.includes(secret), false, secret);
    }
    assert.deepEqual(agent.pending_action, { operation: "PRESS", role: "button", label: "Send", text: { source: "goal:1", characters: 12 } });
    assert.deepEqual(prepared.person.summaryLines, ['Slack: PRESS button "Send"', "Text: typed-UNIQUE"]);
  });

  it("mints a token even without pending_summary (decline still works) but marks it unsendable", () => {
    const prepared = prepareApprovalRequired({ status: "approval_required", binding: { ...BINDING, pending_summary: undefined } }, { app: "Slack" });
    assert.equal(prepared.failClosed, false);
    assert.equal(typeof prepared.resume_token, "string");
    assert.equal(prepared.person.sendable, false);
  });

  it("fails closed with no binding or no session", () => {
    const prepared = prepareApprovalRequired({ status: "approval_required" }, { app: "Slack" });
    assert.equal(prepared.failClosed, true);
    assert.equal(prepared.agentValue.status, "approval_lost");
    assert.equal(prepared.resume_token, undefined);
  });

  it("done strips receipt and decider everywhere", () => {
    const agent = prepareAgentValue({
      status: "done",
      decider: { operation: "PRESS", confidence: 0.9, provider: "jev", model: "x" },
      evidence: { items: [{ role: "statictext", label: "ok" }], receipt: {}, proposal_id: "p" },
      receipt: {},
    });
    assert.deepEqual(agent, { status: "done", evidence: { items: [{ role: "statictext", label: "ok" }] } });
    assert.deepEqual(stripSecrets({ receipt: 1, keep: 2 }), { keep: 2 });
  });

  it("no hint mentions a confirmation that never happened", () => {
    assert.match(agentHintFor("approval_lost_no_ui"), /can't happen in this mode/);
    assert.doesNotMatch(agentHintFor("approval_lost_no_ui"), /did not confirm/);
  });
});

describe("transport", () => {
  it("approve request is exactly op, ids, approve true; decline has no approve key", () => {
    assert.deepEqual(approveRequest(BINDING), {
      op: "approve", proposal_id: BINDING.proposal_id, scope_id: BINDING.scope_id, revision: BINDING.revision, approve: true,
    });
    const decline = declineRequest(BINDING);
    assert.deepEqual(decline, { op: "decline", proposal_id: BINDING.proposal_id, scope_id: BINDING.scope_id, revision: BINDING.revision });
    assert.equal("approve" in decline, false);
  });

  it("CLI argv names the parked session", () => {
    const tail = ["--session", BINDING.session, "--proposal-id", BINDING.proposal_id, "--scope-id", BINDING.scope_id, "--revision", BINDING.revision, "--json"];
    assert.deepEqual(approveArgv(BINDING), ["approve", ...tail]);
    assert.deepEqual(declineArgv(BINDING), ["decline", ...tail]);
  });

  it("mixed goal + decision never plans an engine call", () => {
    const token = mintResumeToken(BINDING);
    assert.equal(classifyParams({ decision: "send", resume_token: token, goal: "x", app: "Slack" }), "invalid_mixed");
    const plan = planResume({ decision: "send", resume_token: token, goal: "x" } as any);
    assert.equal(plan.action, "status");
    assert.equal(isTokenSpent(token), false);
  });
});

describe("outcome mapping", () => {
  const receipt = (fields: any) => ok({ receipt: { schema: "wrangle.receipt.v1", ...fields }, evidence: { items: [] } });

  it(`only effect "${VERIFIED_EFFECT}" gets the visible wording`, () => {
    const verified = map("send", receipt({ dispatch: "delivered", effect: "verified" }));
    assert.equal(verified.status, "done");
    assert.equal(verified.verified, true);
    assert.match(verified.message, /visible/);
  });

  it("unchanged, unverified, missing, unknown, verification_error → couldn't verify", () => {
    for (const fields of [
      { effect: "unchanged" }, { effect: "unverified" }, {}, { effect: "something_new" },
      { effect: "verified", verification_error: "ScopeLost: gone" },
    ]) {
      const mapped = map("send", receipt({ dispatch: "delivered", ...fields }));
      assert.equal(mapped.status, "done", JSON.stringify(fields));
      assert.equal(mapped.verified, false, JSON.stringify(fields));
      assert.equal(mapped.message, "Sent, but Wrangle couldn't verify the result in Slack.");
      assert.match(agentOutputFromMapped(mapped).agent_hint, /Do not claim the result is visible/);
    }
  });

  it("declined receipt → declined, spent", () => {
    const mapped = map("decline", ok({ schema: "wrangle.receipt.v1", dispatch: "refused", effect: "not_applicable", reason: "declined", approval: "spent" }));
    assert.deepEqual([mapped.status, mapped.spend], ["declined", true]);
  });

  it("stale_target, lost_scope, consumed and not_delivered → approval_lost, spent", () => {
    for (const reason of ["stale_target", "lost_scope", "consumed"]) {
      const mapped = map("send", ok({ schema: "wrangle.approval.v1", status: "approval_lost", reason, retryable: false }));
      assert.deepEqual([mapped.status, mapped.spend], ["approval_lost", true], reason);
    }
    const mapped = map("send", receipt({ dispatch: "not_delivered", effect: "not_applicable", reason: "session_locked" }));
    assert.deepEqual([mapped.status, mapped.spend], ["approval_lost", true]);
  });

  it("unknown id and ArgumentError refusals keep the binding: approval_lost without spending", () => {
    const unknown = map("send", ok({ schema: "wrangle.approval.v1", status: "approval_lost", reason: "unknown", retryable: false }));
    assert.deepEqual([unknown.status, unknown.spend], ["approval_lost", false]);
    const refusal = mapResumeOutcome({
      decision: "send", code: 3, stdout: "", stderr: "",
      reply: { ok: false, class: "ArgumentError", error: "Bound approval requires approve: true; a non-true approve is not a decline", terminal: false, retryable: false },
    });
    assert.deepEqual([refusal.status, refusal.spend], ["approval_lost", false]);
    assert.match(agentOutputFromMapped(refusal).agent_hint, /Do not retry on your own/);
  });

  it("DeliveryUnknown (class and receipt) and terminal DriverRefusal → delivery_unknown", () => {
    const byClass = map("send", { ok: false, class: "DeliveryUnknown", error: "interrupted", terminal: true });
    const byReceipt = map("send", receipt({ dispatch: "delivery_unknown" }));
    const driver = map("send", { ok: false, class: "DriverRefusal", error: "helper refused", terminal: true });
    for (const mapped of [byClass, byReceipt, driver]) assert.deepEqual([mapped.status, mapped.spend], ["delivery_unknown", true]);
    assert.doesNotMatch(driver.message, /Nothing was sent/);
  });

  it('exit 5 "No wrangle session" → approval_expired', () => {
    const mapped = mapResumeOutcome({
      decision: "send", code: 5, stdout: "",
      stderr: "BridgeError: No wrangle session at /tmp/w/task-1.sock. Start one with `wrangle open <url>`.",
    });
    assert.equal(mapped.status, "approval_expired");
  });

  it("session closed mid-call, exec timeout/kill → delivery_unknown, spent", () => {
    const closed = mapResumeOutcome({ decision: "send", code: 5, stdout: "", stderr: "BridgeError: The wrangle session closed without replying" });
    const killed = mapResumeOutcome({ decision: "send", code: 1, stdout: "", stderr: "", killed: true });
    const declineClosed = mapResumeOutcome({ decision: "decline", code: 5, stdout: "", stderr: "BridgeError: The wrangle session closed without replying" });
    for (const mapped of [closed, killed, declineClosed]) assert.deepEqual([mapped.status, mapped.spend], ["delivery_unknown", true]);
  });

  it("session_locked does not spend", () => {
    const mapped = map("send", ok({ schema: "wrangle.approval.v1", status: "session_locked", reason: "session_locked", retryable: true }));
    assert.deepEqual([mapped.status, mapped.spend], ["session_locked", false]);
  });
});
