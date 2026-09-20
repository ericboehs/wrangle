# macOS core compatibility probe

Date: 2026-09-19 locally (`2026-09-20T04:11:30Z` report timestamp)

## Method

The checked-in core tier was prepared and observed five times per application:

```bash
script/macos_matrix --tier core --runs 5 --prepare \
  --output /tmp/wrangle-core-probe-5x-final-20260919.json
```

This was a direct native-driver probe. It made no provider request, proposed no action, dispatched no
action, and captured no screenshot. The report retained only counts, completeness, timings, setup
flags, and provenance. It was mode `0600` and contained no window title, AX label/value, window id,
process id, or application content.

Environment:

- macOS 26.6.2 (`25G83`) on arm64.
- Wrangle 0.1.0 native macOS driver.
- One unlocked display; Accessibility available.
- Git base `cd31caacd4796f9c41da070686a666fe6bab6763`, with the harness changes still uncommitted.
- Matrix SHA-256 `ee5630a395989def1c5ec490927c0af5260c3699ba9c9d2aed727530168f6ccb`.
- Exact-root selection found one visible window for every run.

## Result

**20/20 probe runs passed; four of four profiles passed.**

| Profile | Runs | Complete | Nodes | Candidates | Evidence | Ambiguous actions | Median | p95 |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| Finder | 5/5 | yes | 155 | 69 | 125 | 7 across 2 groups | 7.22 s | 7.56 s |
| System Settings | 5/5 | yes | 350 | 83 | 249 | 61 across 4 groups | 8.92 s | 9.02 s |
| Slack | 5/5 | explicitly partial | 211 | 62 | 116 | 12 across 2 groups | 9.83 s | 9.84 s |
| Microsoft Teams | 5/5 | explicitly partial | 55 | 4 | 10 | 3 across 1 group | 9.75 s | 9.81 s |

All observations reported `ax` and `macos_helper_native` provenance. Finder and System Settings were
complete. Slack and Teams retained explicit truncation rather than claiming complete coverage. The
ambiguous operations were counted and omitted by the existing visible-semantics ambiguity guard; an
opaque AX path or ref did not break any tie.

Slack and Teams both verified Electron accessibility setup during every fresh driver run. Their
partial structural probes passing does not establish autonomous task completion or safe controlled
actions. Teams therefore advances only from `pending` to `probe_pass`; it still needs direct task and
controlled-action acceptance before becoming a supported application.

## Cold-launch finding

The first prepared matrix attempt passed Finder, Settings, and Slack but reached Teams before its
first window became visible. All five Teams attempts failed closed with `DriverRefusal`; no substitute
window was selected. The harness originally mislabeled any post-preparation exception as a
preparation failure and used only a fixed settle delay.

The harness now:

- distinguishes preparation failure from a later probe failure;
- polls only pre-attachment application window inventory after explicit `--prepare`;
- retries only `app_not_found` or an empty inventory;
- bounds readiness per profile (60 seconds for Teams);
- stops searching as soon as one initial window inventory is available;
- never searches for a replacement after exact-window attachment.

The final 20/20 run used the corrected harness with all applications already warm. The bounded cold
Teams path has deterministic regression coverage but still needs a clean-process or VM live rerun.

## Decision

The probe harness and core structural matrix are ready to land. Finder, Settings, and Slack retain
their prior controlled-workflow evidence. Teams has repeatable exact-window structural evidence for
the first time, but remains below the task/action support gate.
