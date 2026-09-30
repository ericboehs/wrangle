# macOS application compatibility matrix

The executable source of truth is
[`test/acceptance/macos_apps.json`](../../test/acceptance/macos_apps.json). It defines public fixture
names, safe preparation, structural AX expectations, and optional zero-action task checks. The
harness writes only counts, status, timing, and provider/driver provenance; it does not retain window
ids, process ids, titles, AX labels, AX values, task evidence, or screenshots.

## Status vocabulary

- `controlled_pass`: a controlled workflow has passed on the physical host, but the repeatable matrix
  gate is not yet established.
- `probe_pass`: repeated exact-window structural probes pass, but task/action support remains
  unclaimed.
- `navigation_pass`: a bounded reversible navigation and cleanup passed strict effect verification,
  but broader authenticated workflows remain unclaimed.
- `pending`: no supported-app claim yet.
- `boundary_only`: Wrangle should verify exact-window containment and fail closed around sensitive
  content; it must not enter or extract credentials.
- `primary_driver_separate`: the application has another primary driver. This profile measures only
  the native AX compatibility boundary.

A declared status is historical context, not an exemption. A harness run passes only when every
selected profile satisfies its current machine-readable expectations.

## Matrix

| Profile | Family | Tier | Environment | Current evidence | Next gate |
|---|---|---|---|---|---|
| Finder | Native | Core | Host + VM | Complete fixture observation and one controlled reversible action passed | 20 clean fixture runs after strict effect verification |
| System Settings | Native | Core | Host + VM | Complete observation and reversible navigation passed without changing a setting | 20 clean fixture runs plus permission-denial cases |
| Slack | Electron | Core | VM structure; host authentication | Progressive composer observation, verified unsent draft, and verified clear passed | Five direct task runs, then five Pi runs; Send must remain undispatched |
| Microsoft Teams | Electron | Core | VM structure; host authentication | 5/5 structural probes and 5/5 reversible open/Back workflows passed with strict effects | Authenticated workspace, composer, restart, and Send-policy acceptance |
| TextEdit | Document | Documents | Host + VM | 5/5 structural probes, 5/5 zero-action tasks, and five verified clear/restore cycles passed in Tart | 20 stable fixture trials, then five Pi trials |
| Preview | Document | Documents | Host + VM | 5/5 structural probes and 5/5 zero-action tasks passed against a generated local PDF in Tart | 20 stable fixture trials; remain read-only |
| Calculator | Native | Utilities | Host + VM | 5/5 structural probes, 5/5 zero-action tasks, and five verified input/clear cycles passed in Tart | 20 stable fixture trials, then five Pi trials |
| Obsidian | Electron | Electron | Host + VM | Pending | Disposable vault fixture; no existing notes |
| Visual Studio Code | Electron | Electron | Host + VM | Pending | Disposable workspace fixture; no terminal or command execution |
| 1Password | Security | Security | Host only | Boundary only | Locked/unlocked refusal and containment; no secret extraction |
| Bitwarden | Security | Security | Host only | Boundary only | Locked/unlocked refusal and containment; no secret extraction |
| Safari native AX | Browser | Browsers | Host + VM | Primary Safari JXA driver is established; native AX path unclaimed | Native chrome/window boundary only, separate from the Safari driver suite |
| Google Chrome | Browser | Browsers | Host + VM | Pending | Native AX boundary first; WebMCP remains a separate future capability layer |

Authenticated service tests stay on the physical host unless a dedicated test account is supplied.
Tart images and reports must not contain provider keys, Apple IDs, login sessions, or private UI
content. Tart cannot cover iCloud/App Store sign-in, physical multi-display geometry, Spaces, Secure
Enclave integrations, or human interference; those remain host release gates.

## Tart lifecycle

`script/tart_vm` manages the disposable VM without embedding credentials or private application
state. Its JSON output is limited to VM lifecycle metadata. Clone and snapshot refuse to overwrite an
existing VM, `reset` requires `--replace`, and the clean base names cannot be reset. Its guest
preflight rejects both a running Setup Assistant and Setup Assistant saved in macOS login-restoration
state.

Create and configure a raw base once:

```bash
script/tart_vm bootstrap \
  --source ghcr.io/cirruslabs/macos-tahoe-base:latest \
  --name wrangle-tahoe-base
```

After provisioning a disposable working VM, preserve it under a new name while it is still running:

```bash
script/tart_vm preflight --name wrangle-acceptance
script/tart_vm snapshot \
  --name wrangle-acceptance \
  --target wrangle-provisioned-base-v2
```

`snapshot` repeats the guest preflight, stops the source, and only then clones it. This ordering avoids
preserving Setup Assistant that macOS would restore at the next login. A stopped source is refused
because its guest state cannot be inspected.

Run the repeatable acceptance lifecycle from the stopped provisioned baseline. Clone and reset now
default to validated `wrangle-provisioned-base-v2`; the original `wrangle-provisioned-base` remains
preserved and protected from reset replacement:

```bash
script/tart_vm clone
script/tart_vm start
script/tart_vm preflight
script/tart_vm status
script/tart_vm stop
script/tart_vm reset --replace
```

`start` returns only after Tart reports the VM running and three consecutive guest preflight checks
pass. A newly started VM that fails preflight is stopped before `start` returns an error. Tart's
process output goes to a private file under `~/.wrangle/tart/`. Add `--headless` for a non-GUI lane.
Wrangle, its native helper, fixtures,
and the acceptance harness must execute inside the guest; host Accessibility APIs see only Tart's VM
window. Tart launches its app bundle executable directly, so LaunchServices may omit its launch
date; the native helper binds that host window to the kernel-reported process birth time instead.
This makes host Tart scope stable without pretending the embedded guest UI is exposed through host
Accessibility. Guest application workflows still execute through Wrangle inside the guest. The guest
remains free of API keys, Apple IDs, and authenticated sessions.

The experimental guest backend makes both scopes explicit and refuses all mutations:

```bash
wrangle windows --vm wrangle-acceptance --app Calculator
wrangle tart-observe --vm wrangle-acceptance --app Calculator --json
wrangle attach --vm wrangle-acceptance --app Calculator --session guest
```

It verifies the exact VM is running and its kernel boot generation is unchanged before and after every
guest-helper request. A reboot, replacement, unavailable guest agent, ambiguous guest window, or
changed guest process loses scope. The VM boot identity is also namespaced into the guest process
identity so leases from different VMs cannot alias. Guest sessions are visibly marked read-only and
execution returns `not_delivered/read_only` without invoking the helper. There is no fallback to the
host Tart view or pixel coordinates. A live Calculator trial on 2026-09-24 passed exact inventory,
one-shot observation, session observe/inspect/preview, deterministic `not_delivered/read_only`
execution refusal, unchanged-revision verification, close, and cleanup with zero delivered actions.
The original protocol-1.1 guest helper refused directly launched Finder because it predated the
kernel birth-time identity fix; that trial did not fall back or substitute the root. The repaired
`wrangle-provisioned-base-v2` was subsequently upgraded to protocol 1.2. A randomized canary then
passed two boots with one exact Finder window, stable kernel birth identity, persistent Accessibility
trust, and complete read-only observations. The live acceptance VM was then explicitly reset from
that baseline and passed one-shot and attached-session Finder acceptance plus a further reboot, with
zero delivered actions. See [ADR 0004](../adr/0004-tart-guest-driver.md).

## Commands

List profiles without touching applications:

```bash
script/macos_accept --list
```

Probe one exact, already-visible app window. Preparation is opt-in; prepared profiles use bounded
pre-attachment readiness polling for a cold application launch:

```bash
script/macos_accept finder --runs 5
script/macos_accept finder --runs 5 --prepare --output /tmp/wrangle-finder-acceptance.json
```

Run a tier. Without `--prepare`, every application must already have one visible window or one
uniquely focused window:

```bash
script/macos_matrix --tier core --runs 5 --output /tmp/wrangle-core-acceptance.json
```

Run the profile's bounded read-only task using an explicit provider:

```bash
script/macos_accept finder --task --provider jev --runs 5
```

The checked-in task profiles allow zero delivered actions. They intentionally omit a qualification
receipt, so a provider may prove `DONE` from visible evidence but cannot mutate the application. A
future action profile must set a positive `max_actions` and requires both
`--provider-qualification RECEIPT` and `--allow-actions`; either flag without the other is rejected.
Consequential actions remain blocked by Wrangle regardless.

## Result interpretation

Probe mode checks:

- native driver readiness and unlocked-session state;
- selection of only one exact visible window or one uniquely focused window;
- observation completeness where required;
- minimum candidate and evidence counts;
- ambiguity ceilings where configured;
- required `ax` and `macos_helper_native` provenance.

Task mode additionally checks the allowed terminal status, action ceiling, root preservation,
consistent action accounting, no uncertain delivery, and verified effects for any delivered action.
Reports bind the matrix SHA-256, Git revision, and dirty-worktree state to the result. Exceptions are
reduced to their class name. Detailed AX content remains only in the live process and normal
protected Wrangle event-log boundary.

A supported-app claim requires zero scope, policy, effect, and cleanup failures, followed by at least
95% completion over 20 stable fixture trials. Direct harness trials precede five Pi `computer` trials
so outer-model latency cannot hide driver compatibility failures. The first recorded core probe is
[documented here](macos-core-probe-2026-09-19.md); the controlled Teams navigation and five Pi trials
are [documented separately](macos-teams-controlled-acceptance-2026-09-20.md). The Tart TextEdit,
Preview, and Calculator runs are in the
[2026-09-23 acceptance report](macos-tart-documents-acceptance-2026-09-23.md).
