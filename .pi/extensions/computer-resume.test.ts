import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";

import {
  RESUME_TTL_MS,
  approveArgv,
  classifyParams,
  declineArgv,
  decodeResumeToken,
  isTokenSpent,
  markTokenSpent,
  mintResumeToken,
  planResume,
  prepareAgentValue,
  prepareApprovalRequired,
  resetResumeStateForTests,
  shouldSpendToken,
  stripSecrets,
} from "./computer-resume.ts";

const IDS = {
  proposal_id: "prop-UNIQUE-aaa111",
  scope_id: "scope-UNIQUE-bbb222",
  revision: "rev-UNIQUE-ccc333",
};

beforeEach(() => {
  resetResumeStateForTests();
});

describe("resume token", () => {
  it("roundtrips and hides the three ids in the token string", () => {
    const token = mintResumeToken(IDS, 1_700_000_000_000);
    assert.equal(token.includes(IDS.proposal_id), false);
    assert.equal(token.includes(IDS.scope_id), false);
    assert.equal(token.includes(String(IDS.revision)), false);
    assert.equal(token.startsWith("v1."), true);

    const decoded = decodeResumeToken(token, 1_700_000_000_000);
    assert.equal(decoded.ok, true);
    if (!decoded.ok) return;
    assert.equal(decoded.ids.proposal_id, IDS.proposal_id);
    assert.equal(decoded.ids.scope_id, IDS.scope_id);
    assert.equal(decoded.ids.revision, IDS.revision);
  });

  it("treats tamper or garbage as approval_lost", () => {
    const token = mintResumeToken(IDS);
    const tampered = `${token.slice(0, -2)}ab`;
    assert.deepEqual(decodeResumeToken(tampered), { ok: false, status: "approval_lost" });
    assert.deepEqual(decodeResumeToken("garbage"), { ok: false, status: "approval_lost" });
    assert.deepEqual(decodeResumeToken("v2.aaaa"), { ok: false, status: "approval_lost" });
  });

  it("treats age over 300s as approval_expired", () => {
    const iat = 1_700_000_000_000;
    const token = mintResumeToken(IDS, iat);
    const expired = decodeResumeToken(token, iat + RESUME_TTL_MS + 1);
    assert.deepEqual(expired, { ok: false, status: "approval_expired" });
    const fresh = decodeResumeToken(token, iat + RESUME_TTL_MS);
    assert.equal(fresh.ok, true);
  });

  it("treats a second use after decline or send as approval_lost", () => {
    const token = mintResumeToken(IDS);
    markTokenSpent(token);
    assert.equal(isTokenSpent(token), true);
    assert.deepEqual(decodeResumeToken(token), { ok: false, status: "approval_lost" });
  });

  it("does not spend the token on session_locked", () => {
    assert.equal(shouldSpendToken("session_locked"), false);
    assert.equal(shouldSpendToken("done"), true);
    assert.equal(shouldSpendToken("declined"), true);
    assert.equal(shouldSpendToken("approval_lost"), true);
    const token = mintResumeToken(IDS);
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
      proposal_id: IDS.proposal_id,
      scope_id: IDS.scope_id,
      revision: IDS.revision,
      pending_text: "Send \"hello\" to #general",
      pending_action: {
        operation: "click",
        role: "button",
        label: "Send",
        text: { source: "literal", characters: 5 },
      },
      receipt: { dispatch: "held" },
      receipts: [{ dispatch: "held" }],
      proposal: { proposal_id: IDS.proposal_id },
      ref: 3,
    });

    assert.equal(prepared.failClosed, false);
    assert.equal(typeof prepared.resume_token, "string");
    assert.equal(prepared.pending_text, "Send \"hello\" to #general");

    const agent = prepared.agentValue;
    assert.equal(agent.status, "approval_required");
    assert.equal(agent.resume_token, prepared.resume_token);
    assert.equal("proposal_id" in agent, false);
    assert.equal("scope_id" in agent, false);
    assert.equal("revision" in agent, false);
    assert.equal("pending_text" in agent, false);
    assert.equal("receipt" in agent, false);
    assert.equal("receipts" in agent, false);
    assert.equal("proposal" in agent, false);
    assert.equal("ref" in agent, false);
    assert.deepEqual(agent.pending_action, {
      operation: "click",
      role: "button",
      label: "Send",
      text: { source: "literal", characters: 5 },
    });

    const content = JSON.stringify({ ok: true, value: agent });
    assert.equal(content.includes(IDS.proposal_id), false);
    assert.equal(content.includes(IDS.scope_id), false);
    assert.equal(content.includes(String(IDS.revision)), false);
    assert.equal(content.includes("Send \"hello\" to #general"), false);
  });

  it("fails closed when approval_required lacks engine ids", () => {
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
        proposal_id: IDS.proposal_id,
      },
      receipt: { dispatch: "delivered" },
      receipts: [],
      proposal: { proposal_id: IDS.proposal_id },
      revision: 9,
    });
    assert.equal(agent.status, "done");
    assert.equal("receipt" in agent, false);
    assert.equal("receipts" in agent, false);
    assert.equal("proposal" in agent, false);
    assert.equal("revision" in agent, false);
    assert.equal("receipt" in (agent.evidence ?? {}), false);
    assert.equal("proposal_id" in (agent.evidence ?? {}), false);
    assert.deepEqual(stripSecrets({ receipt: 1, keep: 2 }), { keep: 2 });
  });
});

describe("resume argv", () => {
  it("uses exactly the approve and decline forms", () => {
    assert.deepEqual(approveArgv(IDS), [
      "task", "--json", "--op", "approve", "--approve", "true",
      "--proposal-id", IDS.proposal_id,
      "--scope-id", IDS.scope_id,
      "--revision", IDS.revision,
    ]);
    assert.deepEqual(declineArgv(IDS), [
      "task", "--json", "--op", "decline",
      "--proposal-id", IDS.proposal_id,
      "--scope-id", IDS.scope_id,
      "--revision", IDS.revision,
    ]);
  });

  it("builds those argv forms from a valid resume plan", () => {
    const token = mintResumeToken(IDS);
    const send = planResume({ decision: "send", resume_token: token });
    assert.equal(send.action, "call");
    if (send.action !== "call") return;
    assert.deepEqual(send.argv, approveArgv(IDS));

    const decline = planResume({ decision: "decline", resume_token: token });
    assert.equal(decline.action, "call");
    if (decline.action !== "call") return;
    assert.deepEqual(decline.argv, declineArgv(IDS));
  });

  it("does not build an approve argv when resume also has goal", () => {
    const token = mintResumeToken(IDS);
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
  });
});
