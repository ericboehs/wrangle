# Tart document and utility acceptance — 2026-09-23

## Scope

This run exercised TextEdit, Preview, and Calculator inside a disposable Tart guest. It covered
exact-window structural observation, bounded read-only terminal decisions, and controlled reversible
fixture actions where an application-specific visible postcondition was available.

No API key, Apple ID, authenticated session, private UI content, screenshot, window title, AX value,
reference, process id, or window id was retained in these results.

## Environment

- Guest: macOS 26.6.2 build 25G83, arm64
- Wrangle: 0.1.0 native macOS driver
- Host source revision: `d5ad4a3435fb69072529cb03878d24b7bcaf6105`
- Guest source: the host revision plus the working-tree PDF fixture, readiness polling, and lifecycle
  changes described by this report
- Native helper identity: `com.ericboehs.wrangle.helper`
- Accessibility execution path: Tart guest agent
- Clean stopped baseline: `wrangle-provisioned-base`

The guest report says `git_revision: unknown` because only the required source paths were copied into
the guest. The host revision and dirty source state above are therefore the authoritative source
provenance for this run.

## Results

### Structural probes

All 15 prepared probes passed.

| Profile | Runs | Complete | Candidate count | Evidence count | Ambiguous actions | Median |
|---|---:|---:|---:|---:|---:|---:|
| TextEdit | 5/5 | 5/5 | 1 | 7 | 0 | 2,364.2 ms |
| Preview | 5/5 | 5/5 | 8 | 19 | 4 | 2,316.6 ms |
| Calculator | 5/5 | 5/5 | 22 | 24 | 0 | 1,301.5 ms |

Every observation retained `ax` and `macos_helper_native` provenance. Preview's four ambiguous
actions remained represented as ambiguity metadata rather than being treated as safe selectors.

### Read-only tasks

All 15 bounded tasks returned `DONE`, delivered zero actions, and preserved the exact root.

| Profile | Runs | Actions | Root preserved | Median |
|---|---:|---:|---:|---:|
| TextEdit | 5/5 | 0 | 5/5 | 3,233.2 ms |
| Preview | 5/5 | 0 | 5/5 | 8,678.1 ms |
| Calculator | 5/5 | 0 | 5/5 | 8,745.5 ms |

The read-only decision provider was stock Qwen3.6-35B-A3B through Snapjudge, served from the host over
the private Tart interface. The current adapter records this endpoint as provider `jev`; the served
model was explicitly set to `qwen3.6-35b-a3b-ud-mlx-4bit`. This provenance mismatch is already a known
reason to add a first-class Snapjudge provider identity. Snapjudge remained unqualified for mutations
and was used only for zero-action terminal decisions.

### Snapjudge latency

The server loaded the model in 8.8 seconds, then handled 35 typed-choice requests totaling 90.625
seconds of provider time. Across requests, latency was 2,321 ms median, 5,491 ms p95, 2,589.3 ms mean,
and 881–5,831 ms range. The 15 complete tasks took 121.132 seconds, so provider calls accounted for
74.8% of end-to-end time. Most of the remaining 30.507 seconds was intentional fixture settling and
native observation.

| Profile | Provider calls per task | Provider median per task | End-to-end median | Median provider share |
|---|---:|---:|---:|---:|
| TextEdit | 1 | 906 ms | 3,233.2 ms | 28.1% |
| Preview | 3 | 6,262 ms | 8,678.1 ms | 73.2% |
| Calculator | 3 | 7,306 ms | 8,745.5 ms | 83.9% |

TextEdit had seven evidence items, below Wrangle's provider-selection threshold, so each task needed
only the terminal action decision. Preview and Calculator exceeded that threshold; each task made one
action decision and two evidence-selection decisions. Those 20 evidence calls consumed 58.294
seconds, or 64.3% of all provider time. Within Preview and Calculator alone, evidence selection
accounted for approximately 72% and 71% of provider time respectively. Avoiding a second evidence
choice when the first item already proves a terminal result is therefore the clearest latency target.

The timing also shows a prompt-shape warmup effect rather than one stable service time. TextEdit's
first 833-token request took 5,831 ms, while its next four comparable requests took 881–914 ms.
Calculator's first three 2,223–2,378-token requests took 4,942–5,491 ms, then most comparable requests
fell to 1,949–2,889 ms. A final Calculator evidence request still took 5,130 ms, so first-request
warmup does not explain every tail. Larger acceptance states and repeated evidence scoring explain why
these results are materially slower than the earlier approximately 503 ms frozen-benchmark median.

Returned normalized-entropy confidence also saturated by application: TextEdit ranged from 0.9046 to
0.9526, Preview from 0.9918 to 0.9957, and Calculator from 0.9998 to 0.9999. All decisions were correct
in this read-only run, but these values remain concentration scores, not calibrated correctness or
mutation authorization.

### Reversible fixtures

A deterministic driver-level check ran five cycles each for TextEdit and Calculator:

- TextEdit: clear the disposable field, verify the clear, restore text sourced from the profile's
  exact quoted literal, verify restoration.
- Calculator: enter one local digit, verify the numeric display changed, clear it, verify cleanup.

The recorded run delivered 20 actions across ten cycles. Every dispatch was delivered, every
application-specific postcondition was verified, every cleanup was verified, and every exact root was
preserved. Preview remained read-only; no print, share, annotation, or document mutation was
attempted.

A pre-recorded exploratory cycle exposed state-dependent Calculator control semantics. The driver
re-observed the exact window, verified the visible state, cleaned it, and the final recorded five-cycle
run passed. There were no uncertain deliveries.

## Artifacts

The private JSON artifacts contain counts and provenance only:

| Artifact | SHA-256 |
|---|---|
| `/tmp/wrangle-documents-probe-5x-20260923.json` | `605b74490650ba20f4ffd97c165018d760be8b93ed92f9c027ca3d86149b9184` |
| `/tmp/wrangle-documents-task-5x-20260923.json` | `0d6ed9830f8b1be2c1c04d7f41d916e5e2cbefc3cfe67d9466160acecc1968ae` |
| `/tmp/wrangle-reversible-5x-20260923.json` | `0dcf416d317945b01ea328c5af582b4a1be30d645541d31d9dfec2ed8fd9e270` |

The structural and read-only artifacts bind acceptance matrix digest
`ae951810af5b910024594742a07ccad3dab209a15de4e75b6a1abfa61febd268`.

## Host-window identity follow-up

A visible-demo follow-up found that `tart run` executes the Tart app bundle directly. macOS therefore
reported no LaunchServices launch date even though the process and window were valid, and the native
helper initially refused to create a process-generation identity. The helper now uses
`proc_pidinfo(PROC_PIDTBSDINFO)` kernel birth time, preserving PID-reuse protection without requiring
LaunchServices metadata.

Against the running guest, two consecutive host inventories returned the same process identity and an
exact-window observation completed successfully. The host observation contained zero action
candidates and two evidence items, as expected: host Accessibility sees Tart's VM window, not controls
inside the guest. A separate read-only probe inside the guest found one complete Setup Assistant
window with two unambiguous actions. This confirms that stable host scope and guest UI control are two
distinct layers; the identity fix does not authorize pixel clicking or make guest controls available
to the host driver.

## Outcome and limits

- TextEdit: `controlled_pass`
- Preview: `probe_pass`
- Calculator: `controlled_pass`

These are controlled compatibility results, not broad supported-app claims. Each profile still needs
20 stable fixture trials and the applicable Pi trials. The VM does not cover physical multi-display
geometry, Spaces, Secure Enclave behavior, authenticated applications, human interference, or the
interactive guest Terminal Accessibility identity. The clean `wrangle-provisioned-base` remained
stopped and unmodified. The exercised working clone was deleted by `script/tart_vm reset --replace`;
its stopped replacement was cloned from the provisioned baseline with randomized hardware identity.
