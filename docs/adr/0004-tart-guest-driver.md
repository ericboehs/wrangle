# ADR 0004: add an explicit read-only Tart guest driver

- Status: accepted for prototype
- Date: 2026-09-23
- Extends: [ADR 0002](0002-native-macos-driver.md)

## Context

Wrangle acceptance runs inside Tart because host Accessibility sees only Tart's VM display container,
not the applications rendered inside it. The guest agent can execute Wrangle's native helper in the
logged-in guest session, where exact Calculator, TextEdit, Preview, and Setup Assistant windows are
available through AX.

A visible Calculator demonstration exposed two distinct boundaries. First, `tart run` launches its
host app bundle directly and macOS omits its LaunchServices launch date; the native helper now uses
kernel process birth time for that host identity. Second, stable host scope does not make guest
controls part of the host AX tree. Treating pixels in the Tart view as controls would weaken the
AX-first typed-action contract and exact-root guarantees.

## Decision

1. Add a separate `TartGuestDriver` prototype. It requires an explicit Tart VM name and explicit
   guest application name; neither is inferred from goal text.
2. Execute the existing native macOS helper through Tart's argument-only guest-agent transport. Do
   not use a shell in the guest transport and do not copy provider credentials into the guest.
3. Bind the VM scope to its exact local name and kernel boot generation from `kern.boottime`. Verify
   the VM is running and the boot generation is unchanged both before and after every helper request.
   A stop, reboot, replacement, or failed guest-agent connection loses scope.
4. Preserve the native driver's guest process-generation, CoreGraphics window, bounds, AX path, and
   target-signature checks inside that VM scope.
5. Keep the prototype read-only. `execute` deterministically refuses before dispatch with a
   `not_delivered` result; there is no host-driver or pixel fallback.
6. Expose read-only conformance commands:

   ```bash
   wrangle windows --vm wrangle-acceptance --app "Setup Assistant"
   wrangle tart-observe --vm wrangle-acceptance --app "Setup Assistant" --json
   wrangle attach --vm wrangle-acceptance --app "Setup Assistant" --session guest
   ```

7. Read-only guest sessions may observe, drill, and inspect through `DesktopSessionServer`. Session
   status and observations identify the `tart_guest` driver and `read_only: true`. Preview remains a
   non-mutating diagnostic, while execution returns a durable `not_delivered/read_only` receipt
   without calling the guest helper.
8. Do not connect this prototype to Pi's `computer(goal, app)` tool yet. That interface has no
   explicit VM scope, and one task cannot silently transition from Setup Assistant to Calculator.

## Consequences

- Host code can inventory and observe one exact guest application without pretending Tart's host AX
  tree contains guest controls.
- VM replacement and reboot races fail closed around every observation.
- The guest needs Tart Guest Agent, a stable helper path, Accessibility permission for the guest-agent
  execution identity, and an unlocked logged-in session.
- Read-only observation may enable process-local accessibility setup for supported Electron apps, but
  it cannot dispatch application actions.
- Mutation support requires a separate decision covering guest-side durable dispatch auditing,
  artifact-bound policy, uncertain delivery across guest-agent transport, and explicit Pi VM scope.
- Multi-application workflows require explicit root transitions rather than parsing application names
  from natural-language goals.
