import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { executeComputer } from "./computer-execute.ts";
import { isTokenSpent, lookupPersonView, resetResumeStateForTests } from "./computer-resume.ts";

const SUMMARY = { app: "Slack", operation: "PRESS", role: "button", label: "Send" };
const BINDING = {
  proposal_id: "prop-UNIQUE-aaa111",
  scope_id: "scope-UNIQUE-bbb222",
  revision: "rev-UNIQUE-ccc333",
  session: "task-UNIQUE-ddd444",
  ttl_seconds: 300,
  pending_summary: SUMMARY,
};

type Call = { command: string; args: string[]; options: any };

function fakePi(replies: Record<string, any>) {
  const calls: Call[] = [];
  return {
    calls,
    async exec(command: string, args: string[], options: any) {
      calls.push({ command, args, options });
      const reply = replies[args[0]];
      if (typeof reply === "function") return reply();
      return { stdout: JSON.stringify(reply), stderr: "", code: 0, killed: false };
    },
  };
}

function fakeCtx(answer: boolean | undefined, hasUI = true) {
  const asked: Array<{ title: string; message: string; opts: any }> = [];
  return {
    asked,
    ctx: {
      hasUI,
      ui: answer === undefined ? undefined : {
        async confirm(title: string, message: string, opts?: any) {
          asked.push({ title, message, opts });
          return answer;
        },
      },
    },
  };
}

const parked = (binding: any = BINDING) => ({
  ok: true,
  value: {
    schema: "wrangle.task.v1",
    status: "approval_required",
    app: "Slack",
    message: "A consequential action requires separate approval; nothing was sent.",
    decider: { operation: "PRESS", confidence: 0.9, provider: "jev", model: "m-UNIQUE" },
    pending_action: { operation: "PRESS", role: "button", label: "Send" },
    binding,
  },
});

const delivered = { ok: true, value: { receipt: { schema: "wrangle.receipt.v1", dispatch: "delivered", effect: "verified" }, evidence: { items: [] } } };
const declined = { ok: true, value: { schema: "wrangle.receipt.v1", dispatch: "refused", effect: "not_applicable", reason: "declined", approval: "spent" } };

async function startAndGetToken(pi: any, binding: any = BINDING) {
  pi.replies = undefined;
  const first = await executeComputer(pi, "call-1", { goal: "Press Send in Slack", app: "Slack" }, undefined, undefined, undefined);
  const payload = JSON.parse(first.content[0].text);
  return { first, payload, token: payload.value.resume_token as string };
}

function agentText(result: any) {
  return result.content[0].text as string;
}

beforeEach(() => resetResumeStateForTests());

describe("execute wiring with fake ctx and pi.exec", () => {
  it("first call: agent content has resume_token only; details hold no secrets; person view in memory", async () => {
    const pi = fakePi({ task: parked() });
    const { first, payload, token } = await startAndGetToken(pi);
    assert.equal(payload.value.status, "approval_required");
    assert.equal(typeof token, "string");
    const text = agentText(first);
    for (const secret of [BINDING.proposal_id, BINDING.scope_id, BINDING.revision, BINDING.session, "m-UNIQUE", "pending_summary", "decider"]) {
      assert.equal(text.includes(secret), false, secret);
    }
    assert.deepEqual(first.details, { status: "approval_required", app: "Slack" });
    assert.deepEqual(lookupPersonView("call-1")?.summaryLines, ['Slack: PRESS button "Send"']);
  });

  it("confirm true calls approve with the summary and the abort signal", async () => {
    const pi = fakePi({ task: parked(), approve: delivered });
    const { token } = await startAndGetToken(pi);
    const { ctx, asked } = fakeCtx(true);
    const controller = new AbortController();
    const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token }, controller.signal, undefined, ctx);

    assert.equal(asked.length, 1);
    assert.equal(asked[0].message, 'Slack: PRESS button "Send"');
    assert.equal(asked[0].opts.signal, controller.signal);
    assert.deepEqual(pi.calls.map((call) => call.args[0]), ["task", "approve"]);
    assert.deepEqual(pi.calls[1].args, ["approve", "--session", BINDING.session, "--proposal-id", BINDING.proposal_id,
      "--scope-id", BINDING.scope_id, "--revision", BINDING.revision, "--json"]);
    assert.equal(JSON.parse(agentText(result)).value.status, "done");
    assert.equal(isTokenSpent(token), true);
  });

  it("confirm false calls decline, returns declined, and spends the token", async () => {
    const pi = fakePi({ task: parked(), decline: declined });
    const { token } = await startAndGetToken(pi);
    const { ctx } = fakeCtx(false);
    const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token }, undefined, undefined, ctx);
    assert.deepEqual(pi.calls.map((call) => call.args[0]), ["task", "decline"]);
    assert.equal(pi.calls[1].args.includes("--approve"), false);
    assert.equal(JSON.parse(agentText(result)).value.status, "declined");
    assert.equal(isTokenSpent(token), true);
  });

  it("no UI calls neither approve nor decline, returns approval_lost, keeps the token", async () => {
    for (const ctx of [fakeCtx(true, false).ctx, fakeCtx(undefined, true).ctx, undefined]) {
      resetResumeStateForTests();
      const pi = fakePi({ task: parked() });
      const { token } = await startAndGetToken(pi);
      const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token }, undefined, undefined, ctx as any);
      assert.deepEqual(pi.calls.map((call) => call.args[0]), ["task"]);
      const payload = JSON.parse(agentText(result));
      assert.equal(payload.value.status, "approval_lost");
      assert.match(payload.agent_hint, /can't happen in this mode/);
      assert.equal(isTokenSpent(token), false);
    }
  });

  it("missing pending_summary: no confirm, no engine call, token kept", async () => {
    const pi = fakePi({ task: parked({ ...BINDING, pending_summary: undefined }) });
    const { token } = await startAndGetToken(pi);
    const { ctx, asked } = fakeCtx(true);
    const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token }, undefined, undefined, ctx);
    assert.equal(asked.length, 0);
    assert.deepEqual(pi.calls.map((call) => call.args[0]), ["task"]);
    assert.equal(JSON.parse(agentText(result)).value.status, "approval_lost");
    assert.equal(isTokenSpent(token), false);
  });

  it("explicit decline needs no confirm and calls decline", async () => {
    const pi = fakePi({ task: parked(), decline: declined });
    const { token } = await startAndGetToken(pi);
    const { ctx, asked } = fakeCtx(true);
    const result = await executeComputer(pi, "call-2", { decision: "decline", resume_token: token }, undefined, undefined, ctx);
    assert.equal(asked.length, 0);
    assert.deepEqual(pi.calls.map((call) => call.args[0]), ["task", "decline"]);
    assert.equal(JSON.parse(agentText(result)).value.status, "declined");
  });

  it("ArgumentError refusal on approve keeps the token", async () => {
    const pi = fakePi({
      task: parked(),
      approve: { ok: false, class: "ArgumentError", error: "Bound approval requires approve: true", terminal: false, retryable: false },
    });
    const { token } = await startAndGetToken(pi);
    const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token }, undefined, undefined, fakeCtx(true).ctx);
    assert.equal(JSON.parse(agentText(result)).value.status, "approval_lost");
    assert.equal(isTokenSpent(token), false);
  });

  it("exec killed during approve → delivery_unknown", async () => {
    const pi = fakePi({ task: parked(), approve: () => ({ stdout: "", stderr: "", code: 1, killed: true }) });
    const { token } = await startAndGetToken(pi);
    const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token }, undefined, undefined, fakeCtx(true).ctx);
    assert.equal(JSON.parse(agentText(result)).value.status, "delivery_unknown");
    assert.equal(isTokenSpent(token), true);
  });

  it("mixed goal + decision never reaches the engine", async () => {
    const pi = fakePi({ task: parked() });
    const { token } = await startAndGetToken(pi);
    const result = await executeComputer(pi, "call-2", { decision: "send", resume_token: token, goal: "send", app: "Slack" }, undefined, undefined, fakeCtx(true).ctx);
    assert.deepEqual(pi.calls.map((call) => call.args[0]), ["task"]);
    assert.equal(JSON.parse(agentText(result)).value.status, "approval_lost");
  });
});
