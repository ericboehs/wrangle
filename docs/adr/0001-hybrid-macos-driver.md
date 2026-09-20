# ADR 0001: use a conformance-gated hybrid macOS driver

- Status: superseded by [ADR 0002](0002-native-macos-driver.md)
- Date: 2026-09-18
- Milestones: M1–M2

## Context

Wrangle needs exact root-window discovery, revisioned AX observations, safe dispatch receipts, display
normalization, and Electron accessibility setup. Rebuilding every macOS primitive would delay the
end-to-end alpha, while accepting another tool's safety claims without measuring them would weaken
Wrangle's scope boundary.

`agent-desktop` is Apache-2.0, exposes a versioned JSON contract and C ABI, and already implements
qualified snapshot refs, progressive traversal, actionability checks, and structured delivery
dispositions. The approved plan therefore required an adapter proof before making it an alpha
prerequisite.

## Evidence

The proof was run on the alpha machine against installed 0.8.3 and current release 0.9.2.

- Both versions reported Accessibility and Screen Recording permission.
- Both returned a successful but empty display inventory. `NSScreen` returned both attached displays
  with the expected bounds and scale factors.
- Application-filtered CoreGraphics window inventory returned Slack's exact visible window. Global
  inventory intermittently timed out.
- Slack reported `accessible: false`. Exact-window snapshots refused with
  `ACTION_NOT_SUPPORTED` before and after `AXManualAccessibility=true` was set and read back.
- A single exact-window focus request timed out with delivery `unknown`. It was not retried.
- Direct, bounded macOS metadata reads returned the same Slack window in about 30 ms without reading
  its title or content.

The existing Safari suite remained green during the proof.

### CLI versus C ABI follow-up

On 2026-09-19, the 0.9.2 source revision was built in both release CLI and `release-ffi` modes and
measured on the same M2 Max host (30 warmed samples per path):

| operation | CLI median | long-lived C ABI median |
|---|---:|---:|
| status | 22.47 ms | 5.58 ms |
| fixture snapshot attempt | 211.40 ms | 85.09 ms |

The C ABI removes about 17 ms of process startup on `status` and was 2.5x faster on the attempted
snapshot. It did **not** pass the adoption gate, however. Neither path could snapshot the visible
native fixture on macOS 27: the CLI reported `APP_UNRESPONSIVE`, while the C ABI reported
`ACTION_NOT_SUPPORTED`, so their failure contracts were not equivalent. More importantly,
`ad_snapshot` accepts an application and surface but no exact window identity, whereas Wrangle's
root-surface scope requires one exact window. The benchmark used no mutations and the disposable
fixture was terminated afterward.

The CLI remains the qualified integration for the alpha. A long-lived C ABI adapter may replace it
only after upstream exposes exact-window snapshots, returns equivalent structured dispositions, and
passes the same live conformance tests. The measured startup savings do not justify weakening scope.

### Native exact-window follow-up

The failed live run was later found to be correlated with a locked login session. After unlock, the
0.9.2 CLI observed Finder and System Settings successfully, so the earlier result is not by itself
proof of an upstream macOS 27 defect. Lock state was not recorded during the CLI/C ABI benchmark;
that failure comparison must be rerun before filing it upstream.

Wrangle still needs a bounded fallback for structured snapshot failures and for conformance gaps on
other applications. The shipped helper now supports exact native AX snapshots and actions. It binds a
unique AX window to the selected CoreGraphics id, PID, process generation, and current bounds; emits
snapshot-scoped path refs with stable semantic target keys; revalidates a fresh target signature and
bounds before dispatch; supports progressive traversal; and reports the same dispatch/effect split.
It detects a locked session before AX traversal.

Live acceptance forced one structured, not-delivered snapshot refusal at the adapter boundary and
then completed Finder, Settings, and Slack through the real native helper. Slack required one drill,
then verified an unsent draft and a blank final readback without pressing Send. See the acceptance
report for the harness and safety details.

## Decision

Use a hybrid driver with explicit provenance:

1. `agent-desktop >= 0.9.2` remains a versioned external alpha prerequisite, invoked through its CLI,
   for capabilities that pass Wrangle's conformance suite. Known not-delivered snapshot failures may
   transition explicitly to the named native implementation; mutations never silently change drivers.
2. A small shipped Swift helper owns display discovery, scoped window discovery, process-generation
   identity, frontmost selection, verified `AXManualAccessibility` setup, and the bounded exact-window
   AX snapshot/action fallback used by the three alpha workflows.
3. The helper receives JSON data, contains no model-generated program text, and runs with a minimal
   environment that excludes provider keys.
4. `agent-desktop` ref state lives in a mode-0700 Wrangle-owned temporary directory and is removed
   when the adapter closes. Tracing is not enabled implicitly.
5. Wrangle—not either platform adapter—owns scope, proposals, policy, at-most-once dispatch,
   two-axis receipts, effect verification, event output, and retention.
6. A capability may fall back only to its named native implementation. Fallback and assurance are
   visible in `doctor` and observation provenance.
7. Slack's exact AX observation is a required conformance case. The native implementation binds the
   expanded tree to the selected window and requires progressive drill completion before execution;
   ambiguity, partial coverage, or loss of the exact root still fails closed.

## Consequences

- The alpha does not wait for a complete platform rewrite.
- A fast upstream implementation can replace native fallback primitives after it passes the same
  tests; the product contract does not change.
- The gem ships Swift source and requires the macOS Swift toolchain during alpha. Binary/helper
  distribution remains deferred.
- `agent-desktop` upgrades are not trusted by version alone. Each tested version must pass replay and
  live platform conformance before its mutation capabilities are enabled.
- Slack may force a larger independent AX snapshot primitive if exact-window mapping cannot be fixed
  or supplied upstream. That implementation remains limited to the alpha workflows.
