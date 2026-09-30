# ADR 0002: use the native exact-window macOS driver directly

- Status: accepted
- Date: 2026-09-19
- Supersedes: [ADR 0001](0001-hybrid-macos-driver.md)

## Context

The hybrid alpha preferred `agent-desktop` 0.9.2 and used Wrangle's Swift AX helper as an explicit
fallback. Live acceptance later proved the native path across Finder, System Settings, and Slack,
including progressive observation and a verified Slack draft-and-clear workflow. In contrast, the
external prerequisite caused version-selection failures, duplicated snapshot/ref semantics, required
fallback state, and complicated ordinary Pi launches without improving Wrangle's exact-window
contract.

The `jev-use` prototype also demonstrates the product shape Wrangle wants: keep the AX read/decide/
act/check loop inside the computer-use engine rather than making the outer agent drive adapter
plumbing. Its direct AX implementation is not adopted wholesale: it targets the frontmost app, sets
`AXEnhancedUserInterface`, trims candidate sets, and does not implement Wrangle's scope leases,
one-shot proposals, two-axis receipts, or terminal uncertain delivery.

## Decision

1. The shipped Swift helper is the only macOS platform driver. `agent-desktop` is no longer a runtime
   prerequisite or fallback.
2. Window inventory, display inventory, process-generation identity, Electron setup, AX snapshots,
   progressive drill, and dispatch all come from the same native boundary.
3. One exact CoreGraphics window remains authoritative. AX must uniquely match its PID, process
   generation, bounds, and window identity; no application-wide substitution is allowed.
4. Snapshot refs remain scope-bound capabilities. Every action resolves the path again and validates
   its role, subrole, name, bounds, and observed operation before one dispatch.
5. Wrangle still owns policy, preview/execute separation, leases, at-most-once mutation, dispatch and
   effect receipts, independent readback, and terminal uncertain delivery.
6. `AXManualAccessibility` remains the first Electron/Chromium wake mechanism.
   `AXEnhancedUserInterface` is not enabled in this change. The earlier absolute prohibition was too
   broad—Chromium and Electron do respond to it—but it has documented window positioning, resizing,
   animation, and window-manager side effects. A future fallback may use it only for a confirmed
   Chromium-family process, with previous-state capture, restoration on every exit path, no window
   geometry operation while enabled, and live regression coverage.
7. The primary Pi interface uses the one natural task call defined by
   [ADR 0003](0003-single-task-interface.md). Low-level observe/drill/preview/execute commands remain
   useful for conformance and debugging, not as the normal user experience.

## Consequences

- Ordinary Pi launches no longer depend on selecting a separate `agent-desktop` binary or version.
- Driver provenance is always `macos_helper_native`; there is no runtime transition or fallback state.
- The native helper's correctness and packaging become release-critical.
- Removing a duplicated adapter reduces configuration, failure modes, and test surface while keeping
  the stricter safety properties that are absent from simpler frontmost-app harnesses.
- Electron/WebView applications that expose no useful tree through `AXManualAccessibility` remain
  unsupported until the guarded enhanced-accessibility lifecycle is implemented and tested.
