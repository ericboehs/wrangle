# macOS alpha acceptance

Date: 2026-09-19

## Environment

- macOS 27 on Apple M2 Max.
- Wrangle branch `feature/macos-pi-alpha`.
- `agent-desktop` 0.9.2 release binary built from revision `7a8e4a1`.
- Accessibility and Screen Recording: granted.
- Scope mode: exclusive; one exact root window per session.
- Exact roots: Finder `w-36027`, System Settings `w-36030`, and Slack `w-6711`.

## Correction to the first run

The first run failed closed on all three applications and was initially attributed to macOS 27 AX
window behavior. A later probe found `CGSSessionScreenIsLocked = 1`. After unlock,
`agent-desktop` produced exact Finder and System Settings observations, and the native helper matched
all three exact CoreGraphics roots. The earlier failures are therefore lock-correlated and are not
sufficient evidence of an upstream exact-window defect by themselves.

Wrangle now detects this condition explicitly. `doctor` reports `ready: false` with
`session_locked: true`, and native observation refuses with `session_locked` before walking AX. No
action is dispatched. The CLI/C ABI failure comparison must be rerun with lock state recorded before
it is used in an upstream report.

## Native-path acceptance

This run predates [ADR 0002](../adr/0002-native-macos-driver.md), which removed `agent-desktop` and
made the accepted native path primary. At the time, because the unlocked 0.9.2 CLI no longer failed
on Finder or Settings, a temporary acceptance wrapper
returned one structured, not-delivered `ACTION_NOT_SUPPORTED` response for snapshot commands while
passing every other command to the real binary. This exercised the real Wrangle fallback boundary;
it did not replace action execution, scope validation, the Swift helper, or post-action observation.
The fallback was explicit in observation setup and provenance:

- `fallback.from: agent_desktop`
- `fallback.code: ACTION_NOT_SUPPORTED`
- `snapshot_source: macos_helper_native`
- `coverage.provenance: [ax, macos_helper_native]`

The helper revalidated PID/process generation, exact CoreGraphics window id and bounds, and a unique
AX window on every snapshot and action. Snapshot refs were random, snapshot-scoped, path-based, and
bound to the Wrangle scope. Fresh targets were reobserved before dispatch. Window-management
controls and disabled actions were omitted.

| Workflow | Exact native observation | Controlled action | Result |
|---|---|---|---|
| Disposable Finder fixture | complete exact-root tree | Opened Finder Search; no file operation | delivered, independently verified |
| System Settings | complete exact-root tree | Navigated General → Appearance → General | both navigation effects verified; no setting changed |
| Slack | partial exact-root tree, then complete progressive drill to the composer | Set one 40-character unsent draft, verified it, then cleared it | both delivered; final readback blank; Send never pressed |

Slack's root required one progressive drill. The drilled subtree was complete and exposed the exact
`Message to …` textarea with observed `SET_TEXT` and `CLEAR` operations. After setting text, `Send
now` became observable; it was never proposed or dispatched. Clearing restored the original semantic
revision, removed the Send candidate, and read back one AX formatting newline with no non-whitespace
content. That live result exposed a verifier bug: `CLEAR` required byte-empty text and reported
`unchanged` for the formatting newline. The verifier now treats whitespace-only contenteditable
readback as a verified clear and has a regression test.

The run also exposed two native-action issues that were fixed before final Settings acceptance:

1. Finder's volatile free-space status changed whenever the event log used disk, starving proposals
   even though no offered target changed. Desktop revisions now bind scope, coverage, and offered
   targets, while retaining non-actionable AX context for inspection.
2. Geometry from unrelated scrollbar controls made target identities volatile, and `AXShowMenu` was
   too broad to represent `PRESS`. Stable target keys now use AX path and role; fresh action
   signatures still validate bounds. `PRESS` no longer maps to `AXShowMenu`, and selectable AX rows
   use observed, settable `AXSelected=true` semantics.

Several proposals were correctly refused as `stale_observation` before dispatch while those issues
were diagnosed. Delivered but unchanged safe presses were reported as such; none had uncertain
delivery. No mutation was retried after uncertain delivery.

## Direct-native rerun after ADR 0002

The gate was rerun unlocked after removing `agent-desktop`, with no adapter binary or fallback
configured. `doctor` reported `ready: true`, `session_locked: false`, and `driver: macos_native`.

- Finder exact root `w-36298` was a new empty `/tmp/wrangle-finder-acceptance` fixture. Its complete
  66-candidate observation came directly from `macos_helper_native`; Search was pressed once and the
  resulting change was delivered and independently verified.
- System Settings exact root `w-36221` started on Accessibility. General → Appearance → General were
  each delivered and independently verified. No setting was changed.
- Slack exact root `w-6711` was already on `#notifications` in Boehs. One drill isolated the complete
  composer subtree. Wrangle set the 40-character unsent literal `Wrangle native acceptance — do not
  send.`, verified its exact readback and the appearance of `Send now`, then cleared it. Final
  readback was the expected formatting newline, and `Send now` was absent. Send was never proposed or
  dispatched.

A large Finder home-directory window also exposed a performance boundary: its 1,425-node truncated
snapshot took 15.1 seconds, just beyond the original 15-second helper deadline. The helper deadline
was raised to 30 seconds so a bounded snapshot can report partial coverage instead of being killed at
its completion boundary. The disposable empty fixture remained complete and took 2.0 seconds. This
is a performance issue to optimize, not a reason to silently substitute another driver.

Direct-native event logs are `20260919-acceptance-finder-7341.jsonl`,
`20260919-acceptance-settings-8728.jsonl`, and `20260919-acceptance-slack-12865.jsonl`. They record one,
three, and two verified actions respectively without literal text. All three sessions released their
leases and deliberately left application windows open.

## Safety result

- No Send, Delete, close-window, minimize, zoom, credential, permission, or setting-changing action
  was dispatched.
- The Slack draft was unsent and final readback was blank.
- The Finder fixture and files were not modified. Finder Search remained expanded; the scoped search
  icon press reported no effect, so Wrangle did not claim cleanup it could not verify.
- System Settings was restored to General.
- No screenshot was captured, sent, or persisted.
- Event logs contained action metadata and receipts, not literal draft text or AX pixels.
- All acceptance sessions closed and all scope leases were released.

## Release decision

**Mac alpha controlled-workflow gate: passed on this host.** Exact native observation and scoped
native actions completed the Finder, System Settings, and Slack workflows while preserving stale,
scope, delivery, and independent-effect checks. Safari regressions and the full Ruby suite remain
separate required gates.

The native helper currently runs through the Swift toolchain rather than a packaged binary. The
direct-native rerun is green without the historical wrapper; large AX trees still need snapshot
performance work.
