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

## Guest-aware host orchestration prototype

A later working-tree prototype added a host-side `tart_guest` driver that delegates the existing
native helper through Tart Guest Agent. It binds an explicit VM name, guest application, VM boot
generation, guest process generation, and exact guest window. The VM identity is checked before and
after every helper request, and guest process identities are namespaced by that boot generation.
There is no host Accessibility or pixel fallback.

The deterministic end-to-end fixture covered exact guest inventory, observation, session attachment,
preview, a durable `not_delivered/read_only` execution receipt, close, and lease cleanup. Live
inventory then found exactly one Setup Assistant window in the named working VM and confirmed that
its process identity carried the VM boot namespace. The subsequent live observation stopped with
`DriverUnavailable` because the guest session was locked after a lifecycle restart. It delivered zero
actions and did not substitute a host window or another guest root. This is a correct fail-closed
result, not a completed live observation acceptance; rerun after explicitly unlocking that guest.

## Provisioned-baseline recheck — 2026-09-24

A fresh randomized clone of `wrangle-provisioned-base` completed boot with `.AppleSetupDone` present,
but launched Setup Assistant in MiniBuddy mode. Setup Assistant was not yet in that clone's saved
login-restoration list, so this was inherited launch state rather than restoration caused by the new
clone. The clone was not accepted as reset material.

A separate disposable clone of the pinned Cirrus OCI digest completed boot without Setup Assistant
and without a locked session. This distinguishes the upstream image from the provisioned baseline:
the raw image is complete, while the current provisioned baseline is not fixture-ready. The working
acceptance VM was therefore not reset. `script/tart_vm` now preflights active and persisted Setup
Assistant state before declaring a started fixture ready or preserving a new baseline.

A disposable provisioned clone was then repaired by terminating its active MiniBuddy process,
deleting the user's `MiniBuddyLaunch` and `MiniBuddyLaunchCount` preferences, and retaining
`MiniBuddyShouldLaunchToResumeSetup=false`. Terminating Setup Assistant interrupted the guest-agent
transport, so the mutation was not retried. After a host-level stop and reboot, read-only inspection
verified every intended postcondition. Two consecutive reboot cycles then passed the lifecycle
preflight with Setup Assistant absent, no saved Setup Assistant restoration entry, and an unlocked
session. This proves the state is repairable, but the transport interruption makes that sequence
unsuitable for unattended lifecycle automation. The disposable clone was deleted; the stopped
provisioned base and running acceptance VM were not modified.

A second repaired working clone also disabled inactivity-triggered screen saving in the user-wide
preferences, disabled login-window idle activation, and retained zero display, system, and disk sleep
timers. Manual screen locking remains available. The working clone passed two reboot cycles before
it was preserved as stopped `wrangle-provisioned-base-v2`. A fresh clone with randomized hardware
identity then passed two more reboot cycles with Setup Assistant absent, no saved restoration entry,
an unlocked session, an effective user idle timeout of zero, a login-window idle timeout of zero,
and zero sleep timers. The canary and working clone were deleted. The original
`wrangle-provisioned-base` remains stopped and preserved for comparison; it is not fixture-ready.

After explicit replacement approval, `wrangle-acceptance` was reset from
`wrangle-provisioned-base-v2` and started successfully. Its startup and delayed preflights passed;
Setup Assistant was absent, no Setup Assistant restoration entry remained, the session was unlocked,
the effective user and login-window idle timeouts were zero, and display, system, and disk sleep
timers remained zero.

## Live delegated guest acceptance — 2026-09-24

The installed guest helper still reports protocol 1.1. An initial Finder inventory therefore refused
its directly launched process because that helper predates the kernel birth-time identity fix; no
fallback or substitute Finder root was used. A prepared Calculator fixture exposed exactly one stable
window. The one-shot `tart-observe` result was a complete, read-only `tart_guest` observation with 22
typed candidates and no truncation. A separately
attached guest session then passed observe and inspect, produced a standard non-consequential
proposal from an observed candidate, and returned a durable `not_delivered/read_only` receipt without
invoking guest dispatch. The post-refusal observation retained the same revision and candidate count.
Closing the session preserved the exact root, the session became unavailable afterward, and fixture
cleanup was independently verified. Zero actions were delivered.

The sanitized artifact is `/tmp/wrangle-live-guest-acceptance-20260924.json`, SHA-256
`757bd27670c2274e5f27a9dd66171b0e73174db29c9f63ed138ecd9be4d4eb4e`. Raw observations containing
opaque scope data were deleted. Lifecycle preflight remained safe after cleanup.

## Protocol 1.2 baseline upgrade — 2026-09-24

The current Swift helper source, SHA-256
`08535bc3d7b16280171eaccc802df906fffc9872dc5bf71a0f47fe4098d6bc36`, was compiled inside a
disposable clone, installed into the stable `com.ericboehs.wrangle.helper` bundle, and ad-hoc signed.
The helper reported protocol 1.2, retained Accessibility trust, and remained unlocked across two
working-clone reboots.

A prepared Finder fixture then exposed exactly one window with a kernel birth-time process identity.
Each one-shot observation was complete and read-only with 60 typed candidates. A randomized canary
cloned from the candidate baseline passed two more boots with protocol 1.2, stable Finder identity,
persistent Accessibility trust, and complete Finder observations. No actions were delivered.

The validated candidate was promoted to stopped `wrangle-provisioned-base-v2`; the previous 1.1
baseline was preserved as stopped `wrangle-provisioned-base-v2-helper11`. The prepared Finder window
is intentionally part of the upgraded fixture.

After explicit replacement approval, `wrangle-acceptance` was reset from the upgraded v2 baseline.
Its startup and delayed preflights passed, the helper reported protocol 1.2 with Accessibility trust,
and exactly one Finder window had a stable kernel birth-time identity. One-shot and attached-session
observations were complete and read-only with 60 typed candidates. Session observe, inspect, and a
standard preview passed; execution returned a durable `not_delivered/read_only` receipt. The
post-refusal revision was unchanged, close preserved the exact root, and no leases remained. After a
further stop/start cycle, preflight, helper trust, exact inventory, stable identity, and complete
Finder observation all passed again. Zero actions were delivered, and the VM remained running at the
end of that trial.

The sanitized baseline artifact is `/tmp/wrangle-helper12-finder-acceptance-20260924.json`, SHA-256
`b2585bf078220a0abc84704c76b721f3ea1dcfed3fec75227115a7d23cf3dcff`. The sanitized live artifact is
`/tmp/wrangle-live-finder-acceptance-20260924.json`, SHA-256
`eac1f0963490334ce27b1da660097e9e8fee38b8a04c046459e30a4eb75f3079`. Raw scope artifacts, the
working clone, and the canary were deleted.

The lifecycle default was then promoted from the original provisioned baseline to
`wrangle-provisioned-base-v2`. Bare `clone` and `reset` commands now use v2. Reset replacement
protects the raw base, the original provisioned baseline, the v2 baseline, and any explicitly selected
source; the original baseline remains stopped and preserved for comparison. A disposable live reset
probe without `--source` reported v2 as its source and was deleted while still stopped. Separate reset
attempts against both provisioned baseline names were refused before mutation.

## Guest Pi working clone — 2026-09-24

`wrangle-acceptance` was stopped and a new randomized `wrangle-pi-working` clone was created from the
protected v2 baseline. Pi `0.87.1`, matching the host version and package manifest digest, was installed
with npm lifecycle scripts disabled. The guest's existing Node.js `24.20.0` satisfies Pi's minimum
version. No credential material was copied, and the Wrangle skill and computer extension were
intentionally left for a separate step.

The Tart-provided DNS gateway did not resolve the npm registry, although direct network connectivity
was available. The working clone was configured with explicit public DNS resolvers; registry access
then succeeded and that configuration persisted across reboot. After installation and reboot, Pi's
CLI smoke test, package digest, lifecycle preflight, protocol-1.2 helper trust, unlocked session, and a
complete 60-candidate read-only Finder observation all passed. `wrangle-pi-working` remains running;
`wrangle-acceptance` remains stopped. Neither provisioned baseline was modified.

The sanitized installation artifact is `/tmp/wrangle-pi-working-install-20260924.json`, SHA-256
`47abf00f0d002a3089a2cab29826e9dab98f42bafb271675fd405eac6f95847b`.

## Guest Pi resources and secretless model — 2026-09-24

The repository Wrangle skill and computer extension were copied into Pi's user resource directories
with byte-for-byte matching digests. The guest login path now selects the stable `wrangle-native`
wrapper, so the extension uses the trusted protocol-1.2 helper instead of invoking Swift source under
a different process identity. Pi loaded the skill without diagnostics, registered the `computer`
tool, and selected it during a real read-only Finder prompt.

Secretless outer-model access uses host Ollama with local
`qwen3:30b-a3b-q4_K_M`, digest
`0b28110b7a3364296d5cef609095537189fbb81547761de69fd22dd68d2166c2` and size
18,622,563,179 bytes. The guest stores only a documented dummy Ollama key. Directly binding Ollama to
the Tart bridge accepted TCP connections but did not answer HTTP, and guest Node was separately
blocked from bridge-local network access even though guest curl worked. The accepted path therefore
uses a host-loopback Ollama server, a host bridge proxy restricted to this guest IP, and a persistent
guest LaunchAgent that exposes the endpoint only on guest loopback. The guest LaunchAgent, resource
hashes, model discovery, default model response, Finder observation, and lifecycle preflight all
passed after reboot. The host Ollama and bridge-proxy processes are session-scoped and must be
restarted after a host reboot.

An end-to-end guest Pi smoke selected and invoked `computer` for Finder. It stopped before any action
because Wrangle's separate inner decision provider is intentionally not configured in the guest. This
proves skill routing, extension execution, and secretless outer inference while preserving zero guest
mutations; it does not yet prove a completed Wrangle task.

The sanitized resource/model artifact is
`/tmp/wrangle-pi-working-resources-model-20260924.json`, SHA-256
`beb26741738e3e938e77cfec8dd99f3e8f2f97c526c05c0f5f1e7494f90cc3eb`.

## Guest Pi Finder through host Jev relay — 2026-09-25

A host-side Jev relay now permits guest Wrangle to use the existing host credential without writing it
to disk or copying it into the VM. The relay reads the credential from macOS Keychain into process
memory, targets only the fixed TypeSafe SystemOne endpoint, accepts only the current guest IP on the
Tart bridge, strips the guest's dummy authorization, and enforces five-megabyte request and response
limits. Host-origin requests were refused. A guest LaunchAgent exposes that relay only on guest
loopback; an unsupported path was refused and the LaunchAgent survived a guest reboot. Guest shell
configuration persists only the loopback endpoint, provider name, and a non-secret relay sentinel, so
ordinary Pi and Wrangle invocations need no provider flags. The host relay remains session-scoped and
must be restarted after a host reboot.

Direct guest-local `wrangle task` acceptance ran before Pi acceptance. The exact Finder task finished
`DONE` with complete evidence, one selected evidence item, zero delivered actions, the full
eight-action budget remaining, and its root preserved. Guest Pi then used host Ollama for outer
reasoning, selected `computer` exactly once, invoked guest-local Wrangle, and received the same safe
Jev-backed result. A post-reboot repeat also passed with exactly one `computer` call, no errors, zero
application mutations, and a complete final Finder observation with 60 candidates. No credential
material entered guest configuration, Pi state, reports, or artifacts. A final ordinary invocation,
without explicit model or decision-provider environment on the command line, repeated the same
one-call, zero-action result.

The sanitized relay and Finder artifact is
`/tmp/wrangle-guest-pi-finder-jev-20260925.json`, SHA-256
`6635bf5fb67612ac937c1df49895b82415958165d1f1fda8f8acbc7042824613`.

## Endpoint-bound Jev qualification and guest Pi Calculator — 2026-09-25

Provider qualification now records the configured Jev endpoint, and mutation qualification requires
that the receipt endpoint exactly match the active endpoint in addition to the existing suite,
provider, model, protocol, and age checks. Receipts without an endpoint or with a different endpoint
fail closed. The updated guest gem was installed only in `wrangle-pi-working`; the protected v2
baseline remains unchanged.

Jev passed all eight canonical cases through the exact guest-loopback relay endpoint in 2.892 seconds.
The owner-only receipt is bound to `jev-latest`, the `wrangle.choice.v1` protocol, and the canonical
suite digest, and expires after seven days. A live guest check accepted the exact endpoint and rejected
a mismatched endpoint before any application mutation.

Two direct reversible Calculator preflights ran before the Pi trial. Each delivered the intended digit
and clear sequence and independently returned the display to an unambiguous zero. Both then paused
safely because Jev proposed another button below the confidence floor. The first digit press also
exposed an existing verification limitation: changing the display made the clear action available,
but the generic `PRESS` verifier classified that first action as `unchanged`; the subsequent clear was
verified.

Guest Pi then called `computer` exactly once. Wrangle delivered exactly the intended two `PRESS`
actions, preserved the exact root, retained six actions of budget, and independently finished with a
complete 22-candidate observation and an unambiguous zero display. After cleanup Jev again proposed
another press at 0.39 confidence, so Wrangle correctly refused to deliver it and returned
`low_confidence`. There were no uncertain deliveries or cleanup failures. This is a controlled safe
pause with verified cleanup, not a full terminal-`DONE` mutation pass. Calculator remains open and
cleared.

The sanitized qualification and Calculator artifact is
`/tmp/wrangle-guest-pi-calculator-qualified-20260925.json`, SHA-256
`79de74881fe70664266339c285dd5e09d640c34261c2beef334936d5a81de9f2`.

## Calculator effect verification and controlled rerun — 2026-09-25

The `PRESS` verifier now recognizes a narrowly scoped Calculator digit effect only when the exact
Calculator scope is unchanged, both observations are complete, the observed target is a single-digit
button, each observation has exactly one numeric static display, the display transition is the exact
zero-replacement or digit-append result, and the revision changed. Unrelated revisions, partial or
ambiguous displays, other applications, and unexpected display values remain unverified.

The first direct effect-only preflight proved that all digit/clear actions were now verified, but it
also exposed a separate progress defect: provider history contained only `PRESS` and `verified`, so
a restored zero screen did not tell Jev which buttons had already been pressed. Jev repeated four
reversible cycles until the eight-action budget stopped it; all eight actions were verified and the
final display was zero. Task history now includes the observed operation, role, bounded visible label,
and effect, without refs or literal text values.

With both fixes installed in `wrangle-pi-working`, the final direct preflight delivered and verified
exactly two actions, selected `DONE` at 0.85 confidence, retained six actions of budget, and preserved
the root. Guest Pi then called `computer` exactly once and repeated the same two-action sequence with
two verified effects, `DONE` at 0.88 confidence, complete evidence, and no errors or uncertain
deliveries. An independent final observation found one complete 22-candidate Calculator window with
an unambiguous zero display. Calculator remains open and cleared. This supersedes the earlier safe
pause for this controlled cycle.

The sanitized rerun artifact is
`/tmp/wrangle-guest-pi-calculator-effect-rerun-20260925.json`, SHA-256
`741cf61480413aec73e2580c04c4f7234946ddf71905674c1da2082d625f24b2`.

## Validated Pi baseline snapshot — 2026-09-25

The running, preflight-safe `wrangle-pi-working` fixture was stopped and preserved as the stopped,
randomized `wrangle-pi-base`. The minimal `wrangle-provisioned-base-v2` remained stopped and
unchanged. Lifecycle reset protection now includes the Pi baseline as well as the raw, original
provisioned, and v2 baselines; a live reset-replacement attempt against `wrangle-pi-base` was refused
before mutation.

A disposable randomized canary cloned from the Pi baseline passed startup preflight, Pi and Node
version checks, Wrangle skill and computer-extension digests, native-driver readiness, both guest
proxy LaunchAgents, the endpoint-bound 8/8 Jev qualification receipt, and a complete 22-candidate
Calculator observation with an unambiguous zero display. The canary's new IP was correctly rejected
by the session-scoped host relay allowlist, so each new clone requires an explicit host-relay rebind
before outer-model or Jev traffic can flow. The canary was stopped and deleted after validation.
`wrangle-pi-working`, `wrangle-pi-base`, and v2 remain stopped; no credential material was added to
any image.

The sanitized snapshot artifact is `/tmp/wrangle-pi-base-snapshot-20260925.json`, SHA-256
`3a9142d7104cacf6beab40bc50289e4ea75ca5a94337a8fe941f3f0660a098dd`.

## Outcome and limits

- TextEdit: `controlled_pass`
- Preview: `probe_pass`
- Calculator: `controlled_pass`

These are controlled compatibility results, not broad supported-app claims. Each profile still needs
20 stable fixture trials and the applicable Pi trials. The VM does not cover physical multi-display
geometry, Spaces, Secure Enclave behavior, authenticated applications, human interference, or the
interactive guest Terminal Accessibility identity. During the original run, the then-designated
`wrangle-provisioned-base` remained stopped and unmodified. The later recheck above supersedes its
"clean" classification and preserves the repaired replacement separately as
`wrangle-provisioned-base-v2`.
