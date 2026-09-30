# ADR 0003: make one natural task the primary computer-use interface

- Status: accepted
- Date: 2026-09-19
- Extends: [ADR 0002](0002-native-macos-driver.md)

## Context

The first Pi alpha exposed the safety kernel as an agent workflow: list windows, attach, observe,
drill, search cached candidates, preview, execute, continue, and finish. That made internal capability
identifiers part of the outer model's context and produced avoidable loops. A Slack read needed seven
tool calls even when successful; a failed attempt alternated root observations and large drills until
an extension-level call/read budget stopped it.

`jev-use` demonstrates the better product boundary: one request enters a bounded AX read/choice/act/
check loop. Wrangle needs that shape without adopting its frontmost-app scope, candidate trimming,
confidence-only destructive policy, or retry semantics.

## Decision

1. The primary Pi tool accepts one `goal` and one macOS `app`. It invokes Wrangle exactly once.
2. Wrangle selects the sole visible app window, or the uniquely focused one. Multiple unfocused
   windows are an explicit ambiguity; goal text is never heuristically matched to a window.
3. The complete observe → typed decision → policy → proposal → fresh-target validation → dispatch →
   independent verification loop runs inside `DesktopSessionServer` and uses the existing safety
   kernel rather than a parallel executor.
4. A task may deliver at most eight actions and perform at most three provider-requested progressive
   drills. Any refusal, low confidence, exhausted budget, or uncertain delivery ends the task.
5. A natural imperative authorizes necessary non-consequential actions within its goal. Providers may
   inspect without qualification, but only a current conformance-qualified provider may mutate.
6. Consequential actions stop before dispatch. This first single-call protocol does not weaken
   artifact-bound approval by treating the original broad request as approval or by restarting from
   an unbound confirmation.
7. Exact text comes only from quoted goal spans or named literals copied from the user's request.
   Credentials always hand off.
8. The result contains a natural status, bounded visible evidence, and application-level action
   summaries. It omits scope IDs, refs, proposal IDs, snapshot IDs, and literal text from audit logs.
   Pi remains the writer that summarizes observed evidence; the decision provider only chooses typed
   options.
9. Wrangle releases its exclusive lease and native resources on every exit path and deliberately
   leaves the user-owned application window open.
10. Low-level window/session commands remain CLI debug and conformance interfaces. They are not
    exposed as the normal Pi workflow.

## Consequences

- A request such as “Check the #notifications channel in Boehs Slack” is one `computer` call rather
  than a sequence authored by the outer model.
- Loop limits and cleanup are enforced in the engine, not dependent on the outer agent remembering to
  call `finish`.
- The task cannot yet pause in-process for an artifact-bound consequential approval. It returns
  `approval_required` without dispatch; a future duplex protocol may resume that exact proposal.
- Provider configuration and qualification are operational prerequisites. There is no silent model or
  driver fallback.
- Evidence must be bounded for context safety, so results report explicit truncation and sample both
  the beginning and end of very large actionable views.
