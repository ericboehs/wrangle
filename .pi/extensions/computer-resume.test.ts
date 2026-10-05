import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";

import {
  DEFAULT_TTL_SECONDS,
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
  shouldSpendToken,
  stripSecrets,
} from "./computer-resume.ts";

const BINDING = {
  proposal_id: "prop-UNIQUE-aaa111",
  scope_id: "scope-UNIQUE-bbb222",
  revision: "rev-UNIQUE-ccc333",
  session: "task-UNIQUE-ddd444",
  ttl_seconds: 300,
};

beforeEach(() => {
  resetResumeStateForTests();
});

describe("resume token from binding", () => {
  it("roundtrips binding fields including session and hides them in the token string", () => {
    const token = mintResumeToken(BINDING, 1_700_000_000_000);
    assert.equal(token.includes(BINDING.proposal_id), false);
    assert.equal(token.includes(BINDING.scope_id), false);
    assert.equal(token.includes(String(BINDING.revision)), false);
    assert.equal(token.includes(BINDING.session), false);
    assert.equal(token.startsWith("v1."), true);

    const decoded = decodeResumeToken(token, 1_700_000_000_000);
    assert.equal(decoded.ok, true);
    if (!decoded.ok) return;
    assert.equal(decoded.binding.proposal_id, BINDING.proposal_id);
    assert.equal(decoded.binding.scope_id, BINDING.scope_id);
    assert.equal(decoded.binding.revision, BINDING.revision);
    assert.equal(decoded.binding.session, BINDING.session);
    assert.equal(decoded.binding.ttl_seconds, 300);
  });

  it("treats tamper or garbage as approval_lost", () => {
    const token = mintResumeToken(BINDING);
    const tampered = `${token.slice(0, -2)}ab`;
    assert.deepEqual(decodeResumeToken(tampered), { ok: false, status: "approval_lost" });
    assert.deepEqual(decodeResumeToken("garbage"), { ok: false, status: "approval_lost" });
    assert.deepEqual(decodeResumeToken("v2.aaaa"), { ok: false, status: "approval_lost" });
  });

  it("treats age over ttl_seconds as approval_expired", () => {
    const iat = 1_700_000_000_000;
    const token = mintResumeToken({ ...BINDING, ttl_seconds: 300 }, iat);
    const expired = decodeResumeToken(token, iat + 300_000 + 1);
    assert.deepEqual(expired, { ok: false, status: "approval_expired" });
    const fresh = decodeResumeToken(token, iat + 300_000);
    assert.equal(fresh.ok, true);
  });

  it("defaults ttl to 300 seconds when binding omits ttl_seconds", () => {
    const iat = 1_700_000_000_000;
    const token = mintResumeToken({
      proposal_id: BINDING.proposal_id,
      scope_id: BINDING.scope_id,
      revision: BINDING.revision,
      session: BINDING.session,
    }, iat);
    const decoded = decodeResumeToken(token, iat);
    assert.equal(decoded.ok, true);
    if (!decoded.ok) return;
    assert.equal(decoded.binding.ttl_seconds, DEFAULT_TTL_SECONDS);
  });

  it("treats a second use after decline or send as approval_lost", () => {
    const token = mintResumeToken(BINDING);
    markTokenSpent(token);
    assert.equal(isTokenSpent(token), true);
    assert.deepEqual(decodeResumeToken(token), { ok: false, status: "approval_lost" });
  });

  it("does not spend the token on session_locked", () => {
    assert.equal(shouldSpendToken("session_locked"), false);
    assert.equal(shouldSpendToken("done"), true);
    assert.equal(shouldSpendToken("declined"), true);
    // session_locked path leaves token valid for a later resume
    const token = mintResumeToken(BINDING);
    assert.equal(isTokenSpent(token), false);
    const again = decodeResumeToken(token);
    assert.equal(again.ok, true);
  });
});

describe("agent JSON sanitization", () => {
  it("approval_required agent JSON has resume_token and no secret fields", () => {
    const prepared = prepareApprovalRequired({
      status: "approval_required",
      app: "Slack",
      binding: { ...BINDING },
      pending_text: "Send \"hello\" to #general",
      pending_action: {
        operation: "click",
        role: "button",
        label: "Send",
        text: { source: "literal", characters: 5 },
      },
      receipt: { dispatch: "held" },
      receipts: [{ dispatch: "held" }],
      proposal: { proposal_id: BINDING.proposal_id },
      ref: 3,
    });

    assert.equal(prepared.failClosed, false);
    assert.equal(typeof prepared.resume_token, "string");
    assert.equal(prepared.pending_text, "Send \"hello\" to #general");

    const agent = prepared.agentValue;
    assert.equal(agent.status, "approval_required");
    assert.equal(agent.resume_token, prepared.resume_token);
    for (const key of [
      "proposal_id", "scope_id", "revision", "session", "ttl_seconds",
      "binding", "pending_text", "receipt", "receipts", "proposal", "ref",
    ]) {
      assert.equal(key in agent, false, key);
    }
    assert.deepEqual(agent.pending_action, {
      operation: "click",
      role: "button",
      label: "Send",
      text: { source: "literal", characters: 5 },
    });

    const content = JSON.stringify({ ok: true, value: agent });
    assert.equal(content.includes(BINDING.proposal_id), false);
    assert.equal(content.includes(BINDING.scope_id), false);
    assert.equal(content.includes(String(BINDING.revision)), false);
    assert.equal(content.includes(BINDING.session), false);
    assert.equal(content.includes("Send \"hello\" to #general"), false);
  });

  it("fails closed when approval_required lacks a parked session binding", () => {
    const prepared = prepareApprovalRequired({
      status: "approval_required",
      app: "Slack",
      pending_action: { operation: "click", role: "button", label: "Send" },
    });
    assert.equal(prepared.failClosed, true);
    assert.equal(prepared.resume_token, undefined);
    assert.equal(prepared.agentValue.status, "approval_lost");
    assert.match(String(prepared.agentValue.message), /resume is unavailable/i);
  });

  it("done JSON has no receipt", () => {
    const agent = prepareAgentValue({
      status: "done",
      evidence: {
        items: [{ role: "static", label: "ok" }],
        receipt: { dispatch: "delivered" },
        proposal_id: BINDING.proposal_id,
      },
      receipt: { dispatch: "delivered" },
      receipts: [],
      proposal: { proposal_id: BINDING.proposal_id },
      revision: 9,
      session: BINDING.session,
      ttl_seconds: 300,
    });
    assert.equal(agent.status, "done");
    for (const key of ["receipt", "receipts", "proposal", "revision", "session", "ttl_seconds"]) {
      assert.equal(key in agent, false, key);
    }
    assert.equal("receipt" in (agent.evidence ?? {}), false);
    assert.equal("proposal_id" in (agent.evidence ?? {}), false);
    assert.deepEqual(stripSecrets({ receipt: 1, keep: 2 }), { keep: 2 });
  });
});

describe("parked session transport", () => {
  it("approve request is exactly op, ids, and approve true", () => {
    assert.deepEqual(approveRequest(BINDING), {
      op: "approve",
      proposal_id: BINDING.proposal_id,
      scope_id: BINDING.scope_id,
      revision: BINDING.revision,
      approve: true,
    });
  });

  it("decline request has no approve key", () => {
    const request = declineRequest(BINDING);
    assert.deepEqual(request, {
      op: "decline",
      proposal_id: BINDING.proposal_id,
      scope_id: BINDING.scope_id,
      revision: BINDING.revision,
    });
    assert.equal("approve" in request, false);
  });

  it("CLI argv reaches the parked session by name", () => {
    assert.deepEqual(approveArgv(BINDING), [
      "approve",
      "--session", BINDING.session,
      "--proposal-id", BINDING.proposal_id,
      "--scope-id", BINDING.scope_id,
      "--revision", BINDING.revision,
      "--json",
    ]);
    assert.deepEqual(declineArgv(BINDING), [
      "decline",
      "--session", BINDING.session,
      "--proposal-id", BINDING.proposal_id,
      "--scope-id", BINDING.scope_id,
      "--revision", BINDING.revision,
      "--json",
    ]);
  });

  it("builds those requests from a valid resume plan", () => {
    const token = mintResumeToken(BINDING);
    const send = planResume({ decision: "send", resume_token: token });
    assert.equal(send.action, "call");
    if (send.action !== "call") return;
    assert.deepEqual(send.request, approveRequest(BINDING));
    assert.deepEqual(send.argv, approveArgv(BINDING));

    const decline = planResume({ decision: "decline", resume_token: token });
    assert.equal(decline.action, "call");
    if (decline.action !== "call") return;
    assert.deepEqual(decline.request, declineRequest(BINDING));
    assert.equal("approve" in decline.request, false);
  });

  it("does not reach the engine when resume also has goal", () => {
    const token = mintResumeToken(BINDING);
    assert.equal(classifyParams({
      decision: "send",
      resume_token: token,
      goal: "send it",
      app: "Slack",
    }), "invalid_mixed");

    const plan = planResume({
      decision: "send",
      resume_token: token,
      goal: "send it",
      app: "Slack",
    } as any);
    assert.equal(plan.action, "status");
    if (plan.action !== "status") return;
    assert.equal(plan.status, "approval_lost");
    assert.equal("argv" in plan, false);
    assert.equal("request" in plan, false);
  });
});

describe("resume outcome mapping", () => {
  it("maps delivered receipt to done with evidence and strips receipt", () => {
    const mapped = mapResumeOutcome({
      code: 0,
      stdout: "",
      stderr: "",
      reply: {
        ok: true,
        value: {
          receipt: {
            schema: "wrangle.receipt.v1",
            proposal_id: BINDING.proposal_id,
            dispatch: "delivered",
            effect: "changed",
            reason: "ok",
            scope_id: BINDING.scope_id,
          },
          evidence: { complete: true, items: [{ role: "static", label: "ok" }], selection: "bounded" },
        },
      },
    });
    assert.equal(mapped.status, "done");
    assert.equal(mapped.spend, true);
    assert.deepEqual(mapped.evidence, {
      complete: true, items: [{ role: "static", label: "ok" }], selection: "bounded",
    });
  });

  it("maps decline receipt to declined", () => {
    const mapped = mapResumeOutcome({
      code: 0,
      stdout: "",
      stderr: "",
      reply: {
        ok: true,
        value: {
          schema: "wrangle.receipt.v1",
          dispatch: "refused",
          effect: "not_applicable",
          reason: "declined",
          approval: "spent",
          proposal_id: BINDING.proposal_id,
        },
      },
    });
    assert.equal(mapped.status, "declined");
    assert.equal(mapped.spend, true);
  });

  it("maps approval_lost reasons including not_delivered spent proposals", () => {
    for (const reason of ["stale_target", "lost_scope", "unknown", "consumed"]) {
      const mapped = mapResumeOutcome({
        code: 0,
        stdout: "",
        stderr: "",
        reply: {
          ok: true,
          value: {
            schema: "wrangle.approval.v1",
            status: "approval_lost",
            reason,
            retryable: false,
            proposal_id: BINDING.proposal_id,
            scope_id: BINDING.scope_id,
            revision: BINDING.revision,
          },
        },
      });
      assert.equal(mapped.status, "approval_lost", reason);
      assert.equal(mapped.spend, true, reason);
    }

    const spent = mapResumeOutcome({
      code: 0,
      stdout: "",
      stderr: "",
      reply: {
        ok: true,
        value: {
          receipt: {
            schema: "wrangle.receipt.v1",
            dispatch: "not_delivered",
            effect: "not_applicable",
            reason: "session_locked",
            approval: "spent",
          },
        },
      },
    });
    assert.equal(spent.status, "approval_lost");
  });

  it("maps DeliveryUnknown from ok false and from receipt dispatch", () => {
    const fromClass = mapResumeOutcome({
      code: 4,
      stdout: "",
      stderr: "",
      reply: {
        ok: false,
        class: "DeliveryUnknown",
        error: "Desktop action delivery was interrupted after durable dispatch began",
        terminal: true,
        retryable: false,
      },
    });
    assert.equal(fromClass.status, "delivery_unknown");
    assert.equal(fromClass.spend, true);

    const fromReceipt = mapResumeOutcome({
      code: 0,
      stdout: "",
      stderr: "",
      reply: {
        ok: true,
        value: {
          receipt: {
            schema: "wrangle.receipt.v1",
            dispatch: "delivery_unknown",
            effect: "unknown",
            reason: "interrupted",
          },
        },
      },
    });
    assert.equal(fromReceipt.status, "delivery_unknown");
  });

  it("maps exit 5 No wrangle session to approval_expired", () => {
    const mapped = mapResumeOutcome({
      code: 5,
      stdout: "",
      stderr: "BridgeError: No wrangle session at /tmp/missing.sock. Start one with `wrangle open <url>`.",
      reply: null,
    });
    assert.equal(mapped.status, "approval_expired");
    assert.equal(mapped.spend, true);
  });

  it("maps approval_expired from the parked child", () => {
    const mapped = mapResumeOutcome({
      code: 0,
      stdout: "",
      stderr: "",
      reply: {
        ok: true,
        value: {
          schema: "wrangle.approval.v1",
          status: "approval_expired",
          reason: "expired",
          retryable: false,
        },
      },
    });
    assert.equal(mapped.status, "approval_expired");
    assert.equal(mapped.spend, true);
  });

  it("maps session_locked without spending", () => {
    const mapped = mapResumeOutcome({
      code: 0,
      stdout: "",
      stderr: "",
      reply: {
        ok: true,
        value: {
          schema: "wrangle.approval.v1",
          status: "session_locked",
          reason: "session_locked",
          retryable: true,
        },
      },
    });
    assert.equal(mapped.status, "session_locked");
    assert.equal(mapped.spend, false);
  });
});
