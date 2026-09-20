# Microsoft Teams controlled acceptance

Date: 2026-09-20

## Environment

- macOS 26.6.2 on arm64, unlocked, with Accessibility available.
- Exact visible Microsoft Teams root; signed-out application state.
- Native AX driver with `AXManualAccessibility` verified.
- Base Git revision `109d784b6ba9635be450d506fed0f5f4de3d43d4`; progressive-observation changes were uncommitted during the controlled actions.
- Inner decision provider: `jev/jev-latest`.
- No screenshot or OCR.

## Five Pi read-only trials

Pi was invoked non-interactively with explicit benchmark-only configuration:

- outer provider/model: `ollama/glm-5.3-flash`;
- thinking: `high`;
- exactly one enabled tool: `computer`;
- no Pi session persistence;
- one requested `computer` call;
- read-only goal requiring no navigation, typing, calling, or sending.

Artifact: `/tmp/wrangle-real-pi-teams-5x-ollama-glm53f-20260920.json`.

| Measure | Result |
|---|---:|
| Clean exits | 5/5 |
| Exactly one `computer` call | 5/5 |
| `done` | 5/5 |
| Zero delivered actions | 5/5 |
| Exact root preserved | 5/5 |
| Tool errors | 0 |
| Malformed JSON events | 0 |
| Non-empty Pi stderr marker | 5/5 |
| Wall median / p95 | 11.35 s / 11.95 s |
| `computer` median / p95 | 5.68 s / 6.35 s |

All inner decisions retained `jev/jev-latest`; all outer turns reported
`ollama/glm-5.3-flash`. Ollama pricing was unreported. Pi exited cleanly and returned no tool error in
every run, but emitted non-empty stderr; the benchmark retained only that marker, not its contents.

## Progressive-observation defect

The Teams skeleton was explicitly partial: four candidates with three ambiguous actions. A safe
request to open the Join-a-meeting form selected an observed button, but the old task path called
`preview` against the partial root and failed with `PartialObservation`. It never attempted a deeper
bounded root observation, even though the native driver already supported one.

A depth-24 exact-root probe completed successfully in 2.59 seconds with 61 nodes, four candidates,
and no truncation. The task loop now uses that existing bounded path only after a provider selects a
non-terminal action from a partial root:

1. Keep the exact attached root and process identity.
2. Request a deeper bounded root observation.
3. Fail closed if it is still partial.
4. Discard the skeleton action choice.
5. Require the provider to decide again from the completed observation.
6. Preserve full-observation mode for pre-dispatch freshness and post-dispatch effect capture.
7. Never replace a partial drilled subtree with a different root view.

The automatic escalation does not consume one of the three provider-requested drill slots. It does
not carry an opaque ref, path, list position, or provider choice across the perception boundary.

## Controlled navigation and cleanup

Before provider qualification, the same task reached policy and stopped as
`provider_not_qualified`, with zero actions. The full observation was complete and the second Jev
decision selected the same visible `PRESS` operation with confidence 0.83.

A fresh Jev qualification receipt passed 8/8 canonical cases. Two one-action tasks then exercised the
complete pipeline:

| Action | Skeleton → full decision | Policy | Dispatch | Intended effect |
|---|---|---|---|---|
| Open the Join-a-meeting form | `PRESS` 0.92 → `PRESS` 0.81 | standard | delivered once | verified |
| Return with Back | `PRESS` 1.00 → `PRESS` 0.98 | standard | delivered once | verified |

Each task used a one-action budget, so `budget_exhausted` after the verified delivery was expected and
prevented any second mutation. Separate read-only tasks then confirmed the form was visible (`done`,
0.98) and the initial screen was restored (`done`, 0.70).

Durable event logs:

- `20260920-task-f1894df26f83-79875.jsonl` — open form;
- `20260920-task-4435514af80b-85714.jsonl` — Back cleanup.

Both logs show partial observation, an initial decision, complete `observe_escalated`, a second
decision, standard policy, one durable delivery, target-specific `verified` effect, and clean close.
They contain metadata rather than UI labels or values.

## Five qualified reversible trials

Artifact: `/tmp/wrangle-teams-reversible-5x-20260920.json` (mode `0600`).

A new Jev qualification passed 8/8 canonical cases. Each recorded trial used two independent
one-action tasks: open the form, then return with Back. Every task required confidence 0.65 or higher,
standard non-consequential policy, an exact preserved root, complete action-path observations, one
durable delivery, and strict target-specific verification.

| Measure | Result |
|---|---:|
| Completed reversible trials | 5/5 |
| Delivered actions | 10/10 |
| Strictly verified effects | 10/10 |
| Complete action observations | 10/10 |
| Exact root preserved | 10/10 |
| Uncertain deliveries | 0 |
| Text or external mutations | 0 |
| Open confidence range | 0.78–0.86 |
| Back confidence | 0.98 in 5/5 |
| Open median / p95 | 12.80 s / 12.87 s |
| Back median / p95 | 12.70 s / 12.83 s |
| Non-empty stderr marker | 0/10 |

Three preflight cycles also delivered and verified both directions, but were excluded from the
recorded five because supplementary read-only Jev confirmations—not the actions or effect
verification—hit their terminal confidence floor after cleanup. The final criterion measures the
qualified reversible actions directly. After the recorded run, a local complete AX observation
confirmed the initial launcher was present and form-only controls were absent.

The qualification receipt was deleted after the run. The report stores counts, timings, confidence,
provenance, policy class, and receipt states, but no UI labels, values, refs, window identifiers,
process identifiers, or screenshots.

## Safety result

- No meeting was joined.
- No meeting code, credential, message, or other text was entered.
- No call, send, sign-in, setting change, or external action occurred.
- No action was retried.
- The initial Teams screen was restored and confirmed.
- Every task released its exact-window lease and left the root window open.
- Raw task responses containing bounded visible evidence were deleted after producing a sanitized summary.

## Decision

**Teams controlled reversible-navigation acceptance passed repeatedly.** The new progressive path
reached policy, durable dispatch, fresh exact-root observation, and strict target-specific effect
verification in both directions across five recorded cycles. This does not establish authenticated
workspace, composer, Unicode-literal, restart, or Send-policy acceptance; Teams remains below the
full supported-app gate.
