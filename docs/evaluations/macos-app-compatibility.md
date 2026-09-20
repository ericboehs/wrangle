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
| Microsoft Teams | Electron | Core | VM structure; host authentication | 5/5 exact-window structural probes passed with explicit partial coverage | Direct task and controlled-action acceptance |
| TextEdit | Document | Documents | Host + VM | Pending | Read-only fixture followed by verified-then-cleared exact text |
| Preview | Document | Documents | Host + VM | Pending | Read-only local PDF fixture; no print, share, or annotation |
| Calculator | Native | Utilities | Host + VM | Pending | Read-only structure followed by reversible local input |
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
[documented here](macos-core-probe-2026-09-19.md).
