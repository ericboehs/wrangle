# Wrangle: scoped computer use

- **Status:** Draft
- **Target:** Post-0.1 alpha redesign
- **Last updated:** 2026-09-18
- **Primary user:** AI coding and assistant agents

This document defines what Wrangle should become and how success will be judged. It deliberately does
not choose the core implementation language, platform bindings, browser protocols, process framing,
or package boundaries. Those choices belong in architecture decision records after the first
perception prototype supplies measurements.

Normative words such as **MUST**, **SHOULD**, and **MAY** describe product requirements.

## Summary

Wrangle is a fast, policy-gated computer-use engine that gives an agent a bounded part of a computer
and no more than that. A session may be scoped to one root surface, one application, or the desktop.
One root surface is the default: a window for a desktop driver and a tab for a browser driver.

Wrangle observes a scope, offers typed actions grounded in that observation, asks a fast decision
provider to choose among them, validates the choice in deterministic code, and revalidates the target
before executing it. It fails closed when the scope, target, document, or delivery outcome is no
longer known.

The durable product is a CLI and compact machine protocol. A thin Pi extension consumes that protocol
without making the agent parse human terminal output. Safari becomes the first browser driver rather
than the definition of the product. Later browser drivers cover Chromium and Gecko; a general macOS
driver is the first milestone of this redesign; Linux support begins with Wayland.

The product's distinguishing promise is **scoped computer use**, not unrestricted desktop control:

> An action may mutate only a target offered by the pinned scope and observed revision. It is
> dispatched at most once. If delivery cannot be proven, Wrangle stops rather than trying again.

## Problem

Current computer-use systems tend to combine several expensive or unsafe properties:

- every step sends a screenshot to a large generative model;
- the model generates coordinates, selectors, commands, or text that were never observed;
- the entire desktop is implicitly in scope;
- an action is retried when transport failure makes its first delivery uncertain;
- full observations and repetitive transcripts are returned to the calling agent;
- provider, privacy, or assurance boundaries change silently when a preferred path fails.

That makes computer use slow, costly, context-heavy, and difficult to reason about. Browser-specific
automation is faster and better grounded, but each engine has different attachment and debugging
interfaces. Native applications expose inconsistent accessibility trees, and Electron/Chromium apps
commonly leave their useful tree disabled until assistive technology explicitly enables it.

Wrangle needs one control loop that preserves the strongest available grounding for each surface,
while keeping perception, platform drivers, decision providers, and agent integrations replaceable.

## Product principles

1. **Scope is authority.** A goal is not permission to control the whole machine. The selected scope
   defines where actions may land.
2. **Observe before acting.** Every mutation refers to a candidate from a specific observation.
3. **Models assess; code permits.** Decision providers return typed choices and probabilities.
   Deterministic policy validates and authorizes their use.
4. **Uncertain delivery is terminal.** Wrangle never retries a mutation whose first delivery may have
   happened.
5. **Use the strongest available grounding.** Browser DOM identity is stronger than accessibility
   identity, which is stronger than OCR geometry. A fallback may not silently weaken the guarantee.
6. **Text is supplied, not invented.** Text comes from exact goal spans or explicit literals. Missing
   text is a handoff, not an invitation to generate prose.
7. **Privacy boundaries are explicit.** Pixels stay local and ephemeral by default. Local-to-cloud
   provider fallback is never implicit.
8. **Agent context is a product budget.** Normal progress stays inside Wrangle. The caller receives
   only the outcome or the information needed for its next decision.
9. **Speed is measured by phase.** Startup, perception, decision, policy, action, and verification are
   timed separately. Optimizations follow measurements.
10. **Alpha means design freedom.** Backward compatibility with Wrangle 0.1 is not a requirement.

## Goals

### Product goals

- Control native macOS and Electron applications through one scoped session model.
- Preserve the current fail-closed Safari safety properties while making Safari a driver.
- Add Chrome and Firefox through a shared browser capability model.
- Support local Jev-like decision providers without coupling the core to Python or a model runtime.
- Keep ordinary successful output near 250 tokens (about 1 KiB) for the calling agent.
- Permit root-surface-, application-, and desktop-scoped work, with one surface as the safe default.
- Make consequential operations visible to configurable policy before dispatch.
- Provide compact replayable evidence for debugging, benchmarking, and provider comparison.
- Keep the durable engine useful outside Pi while providing a native, low-context Pi integration.
- Leave a credible path to Wayland-first Linux support.

### First whole-Mac alpha goals

The first redesigned alpha targets Eric's current macOS release on Apple Silicon. A broader public
version and hardware floor will be set from spike evidence rather than assumed.

It MUST operate against:

- Finder and macOS file dialogs;
- System Settings;
- Slack and Microsoft Teams, including automatic Electron accessibility enablement.

It MUST support:

- pressing or clicking an observed control;
- entering exact supplied text;
- scrolling;
- choosing observed menu items;
- Enter, Escape, Tab, arrow keys, Space, and a bounded set of deterministic navigation keys;
- waiting, finishing, refusing, and requesting input or approval.

### Non-goals for the first alpha

- Compatibility with the 0.1 Ruby API or CLI grammar.
- Arbitrary model-generated coordinates, selectors, scripts, shell commands, or key sequences.
- Generative text writing inside Wrangle.
- Reading, storing, or typing passwords or secret values.
- Sending screenshots to a decision provider.
- Cloud computer vision by default.
- Persisting screenshots or screen recordings by default.
- Drag and drop, arbitrary clipboard use, or arbitrary keyboard shortcuts.
- Claiming all macOS applications work equally well.
- General Linux desktop support in the first milestone.
- Polished human UX at the expense of a stable, compact machine interface.

## Terminology

- **Core:** sessions, run loop, policy, event log, output shaping, and protocol coordination.
- **Driver:** a platform- or application-specific implementation that lists scopes, observes one,
  validates candidates, acts, and reports delivery.
- **Provider:** a remote or local typed decision engine that satisfies Wrangle's Jev-compatible
  provider contract.
- **Surface:** something a driver can observe and control, such as a window, tab, dialog, or device.
- **Scope:** the set of surfaces a session is authorized to control.
- **Root surface:** the smallest independently scoped surface to which a session was initially
  attached: normally a desktop window or browser tab.
- **Observation:** a bounded, revisioned description of the selected scope.
- **Candidate:** one typed action grounded in an observation.
- **Receipt:** the driver's separate account of dispatch certainty and observed effect.
- **Scope expansion:** adding another root surface or application to a running session.
- **Policy profile:** deterministic thresholds and rules for safe, consequential, and forbidden
  actions for a driver or environment.
- **Provenance:** how an item was perceived, such as `dom`, `ax`, `ocr`, or `ax+ocr`.
- **Run:** one bounded attempt to satisfy a goal inside a session.

## Users and use cases

### Primary user

The primary user is an AI agent that needs to inspect or manipulate a real user interface without
spending its own context on every observation and click. The agent needs a small, predictable reply
and an explicit handoff when human or generative judgment is genuinely required.

Humans may use the CLI directly, but human formatting is a rendering of the canonical machine events,
not an interface integrations must parse.

### Initial use cases

- Locate and select a known file in Finder or a file dialog.
- Inspect a System Settings state and change a reversible setting when policy permits.
- Navigate Slack or Teams to a known conversation.
- Enter an exact supplied draft into an Electron composer.
- Stop for approval before sending the message.
- Explain a stall or missing value without returning the whole accessibility tree.

### Future use cases

- Drive a handed-over or dedicated Safari, Chrome, or Firefox tab, with broader window scope when
  explicitly selected.
- Perform multi-application workflows under an explicitly selected application or desktop scope.
- Run the same browser workflows on Linux.
- Use a local typed-choice provider for private, low-latency decisions.

## Requirements

### 1. Sessions and scopes

1. Wrangle MUST support `surface`, `application`, and `desktop` scopes. A driver MUST declare what its
   root surface means.
2. The default MUST be one root surface: a window for a desktop driver and a tab for a browser driver.
3. A desktop window scope MAY include menus, sheets, popovers, and dialogs that the driver can
   attribute to the root through an ownership relationship or an observed action that opened them.
   Sharing a process ID alone is not enough.
4. A new root surface, application, or process MUST be treated as scope expansion, not silently folded
   into the current scope.
5. Scope expansion MUST pass through policy. The selected profile may allow, ask, or refuse it.
6. Every observation and action receipt MUST identify the active scope and revision with opaque,
   session-stable identifiers.
7. A session MUST stop or ask when it can no longer identify its root surface unambiguously.
8. Drivers MUST expose whether Wrangle owns a surface and what closing the session is permitted to
   close. A handed-over surface MUST not be closed by default.
9. Users MUST be able to select an initial desktop window in all three ways:
   - choose an opaque ID from a list;
   - place a window frontmost during a short countdown;
   - select a window with an interactive picker.
   Browser drivers MUST provide an equivalent unambiguous tab selector.
10. Scope metadata returned to the caller MUST omit sensitive titles, URLs, or content unless needed
    for disambiguation or explicitly requested.
11. Every executing session MUST declare an `exclusive` or `cooperative` concurrency policy.
    `exclusive` is the default.
12. Exclusive sessions MUST refuse another executing session whose surface, application, or desktop
    scope overlaps it. Preview-only sessions MAY coexist.
13. Detected human input or unexpected focus change MUST invalidate the pending observation. An
    exclusive session pauses or stops; a cooperative session may reobserve and continue, but may not
    dispatch the pending action.
14. A crashed or closed session MUST not block later attachment indefinitely. Recovering its scope
    claim MUST not close or mutate the surface.

### 2. Perception and observations

1. A macOS observation MUST combine the accessibility tree with optional local OCR.
2. Pixels MUST remain on the local machine and MUST NOT be sent to a remote or local text decision
   provider.
3. Captures MUST be ephemeral by default. Persisting raw or annotated images requires an explicit
   debugging option.
4. Perceived items MUST retain provenance: `ax`, `ocr`, `ax+ocr`, `dom`, or another driver-declared
   source, plus whether the item is visible, offscreen, or visibility-unknown.
5. The driver MUST distinguish a semantic accessibility action from a coordinate fallback. Offscreen
   accessibility controls MUST be offered separately and MUST NOT receive a coordinate fallback.
6. A coordinate candidate MUST remain inside the selected scope and MUST be revalidated against the
   current window geometry immediately before dispatch. Display changes, scale changes, window moves,
   minimization, and movement between Spaces MUST invalidate coordinate observations.
7. The observation MUST identify the focused field, when one can be identified, including its role,
   label, value or safe value summary, and whether its value can be read back.
8. Refs MUST be opaque and valid only for the observation that issued them.
9. A repeated observation MUST express deltas rather than repeat unchanged text and candidates in
   agent-facing output.
10. Perception SHOULD avoid re-reading unchanged screen regions. Every observation MUST report how
    much work each perception source performed and how long it took.
11. A source that times out, reaches a node cap, truncates text, or omits part of the scope MUST report
    that limitation. Silence MUST NOT be interpreted as complete coverage.
12. If a permission required by the selected driver capability is absent, the driver MUST fail closed
    with one compact remediation, not return an empty observation that could be mistaken for the
    screen. A declared AX-only mode MAY operate without screen capture, but selecting it is an explicit
    capability change rather than a silent fallback.
13. Perception and coordinate normalization MUST work across attached displays with different origins
    and scale factors. A main-display-only observation may not be presented as whole-Mac coverage.
14. Text observed from applications, documents, and websites is untrusted data. It MUST NOT alter
    configuration, policy, scope, execution permission, or the set of available driver operations.

#### Electron and Chromium accessibility

1. The macOS driver MUST detect Electron/Chromium applications or the characteristic minimal
   accessibility stub they expose before assistive technology is enabled.
2. It MUST set `AXManualAccessibility=true` on the application's root `AXUIElement`, once per process
   ID, before relying on the tree.
3. This bounded, documented observation-enabling side effect is allowed during preview without execute
   permission. It MUST be disclosed as a driver capability and logged separately from user-content
   mutation.
4. It MUST verify that a useful tree becomes available. A successful attribute write followed by the
   same stub is not success.
5. It MUST reapply the attribute after a process restart and MAY reapply it when a previously useful
   tree collapses to a stub.
6. It MUST prefer `AXManualAccessibility`. `AXEnhancedUserInterface` MAY be evaluated only as a
   confirmed Chromium-family fallback because it has known window positioning, resizing, animation,
   and window-manager side effects. Such a fallback MUST capture and restore the prior value on every
   exit path, MUST NOT coexist with window geometry actions, and MUST pass live regression coverage.
7. Electron tree enablement MUST be idempotent and represented in the compact event log.
8. The acceptance suite MUST demonstrate useful Slack and Teams trees after enablement. A fixed node
   count is not required, because application releases change their trees.
9. Electron `contenteditable` fields MUST be treated as a distinct capability. A text action MUST not
   double-insert, MUST obtain a fresh ref after invalidation, and MUST use readback rather than a
   platform API's success flag as proof.
10. If the field cannot be read back, the action MUST stop as unverified rather than retype the value.

### 3. Candidates and actions

1. A candidate MUST contain a typed operation, opaque target reference where applicable, concise
   label, provenance, visibility, and enough driver-owned guard data to revalidate it.
2. The decision provider MUST choose from candidates Wrangle supplied. It MUST NOT create a selector,
   coordinate, key sequence, command, URL, file path, or unobserved option value.
3. Every action request MUST carry:
   - the scope and observation revision;
   - the selected candidate reference;
   - a unique mutation nonce;
   - an exact text literal when the candidate requires one.
4. Immediately before dispatch, the driver MUST revalidate the scope, revision, target, and required
   input focus. A key or text action MUST be refused if the scoped root or attributed child does not
   hold focus.
5. A receipt MUST report dispatch separately from effect:
   - **refused:** policy or validation stopped the action before a dispatch attempt;
   - **not delivered:** dispatch was attempted but the driver can prove nothing was sent;
   - **delivered:** the driver can prove the operation was sent or accepted;
   - **delivery unknown:** dispatch may have happened, but cannot be proven either way.
6. A delivered receipt MUST separately classify the observed effect as `verified`, `unchanged`,
   `unverified`, or `not applicable`. Delivery alone MUST NOT be described as proof that the intended
   UI outcome occurred.
7. `delivery unknown` MUST poison the session for mutation. The action MUST never be retried.
8. A delivered action with no observed effect MUST be reobserved or approached differently; it MUST
   NOT be blindly repeated.
9. Wrangle MUST record a delivered or potentially delivered action before attempting the next
   observation, so a failed read cannot erase the mutation from history.
10. Text entry MUST preserve the supplied Unicode string exactly and be verified against the complete
    readable field value. A driver that cannot preserve or read it back MUST refuse or stop without
    typing again.
11. Exact text MAY come only from an explicit literal or an exact span of the user's goal. Missing text
    MUST produce a compact input request.
12. Passwords, recovery codes, API keys, and other secret values MUST NOT be accepted as literals.
    Wrangle MAY operate observed password-manager and SSO controls without reading their secrets.
13. Preview MUST be the default. Mutation requires explicit execution permission from the CLI or
    integration. Observation-enabling behavior explicitly listed in driver capabilities is not
    user-content mutation.
14. The initial macOS action set MUST be bounded to observed presses/clicks, exact text entry, scroll,
    observed menu choices, Enter, Escape, Tab, arrows, Space, deterministic navigation keys, wait,
    done, and refusal.
15. Arbitrary keyboard chords, clipboard content, drag paths, and free coordinates are outside the
    initial action space.

### 4. Policy and consequential actions

1. The core MUST evaluate policy before dispatching every mutation.
2. Policy MUST distinguish routine reversible actions from consequential actions such as:
   - sending external communication;
   - deleting or overwriting data;
   - purchasing, booking, submitting, publishing, or deploying;
   - changing security, privacy, or permission settings;
   - expanding scope to a new root surface or application.
3. A policy profile MUST resolve each class to allow, ask, propose-only, or refuse.
4. Defaults MAY differ by driver because a browser DOM driver and an OCR coordinate driver make
   different guarantees.
5. Driver-specific defaults MUST be declared and inspectable. They MUST NOT weaken global invariants.
6. Semantic provider scores MAY raise concern or request approval, but MUST NOT override a
   deterministic refusal or lower a deterministic risk classification.
7. Approval MUST identify the exact pending action and observation. It MUST not become blanket
   permission for a freshly observed replacement.
8. Policy decisions and approvals MUST appear in the event log without exposing sensitive content.

### 5. Decision providers

1. The core MUST communicate with decision providers through a versioned out-of-process protocol.
2. The provider boundary MUST be vendor-, model-, and runtime-neutral. Adding a conforming local
   model MUST NOT require changing or releasing the core.
3. Providers MAY be executables, long-lived local services, or adapters for Jev-compatible HTTP
   endpoints. Their transport MUST NOT change the typed meanings visible to the core.
4. The protocol MUST define categorical choice, ordinal score, and boolean probability. A provider
   MUST declare which it implements natively or can map faithfully. Categorical choice with a full
   distribution, confidence, model identity, and usage/timing metadata is the minimum computer-use
   capability.
5. Every provider implementation MUST pass a shared conformance suite for handshake, declared
   capabilities, typed responses, malformed responses, timeouts, cancellation, and model identity.
6. API compatibility alone MUST NOT imply behavioral compatibility. Each model must be evaluated on
   Wrangle's recorded decision distribution before policy permits automatic mutation.
7. Provider responses MUST be validated for schema, offered-option coverage, normalized probability
   mass, and choice/distribution consistency before policy may use them.
8. A provider MUST NOT generate action arguments or free text.
9. Provider selection MUST be deterministic and visible in run evidence. Desktop tasks MAY use the
   documented built-in `jev` default when no CLI or environment override is present. Wrangle MUST NOT
   discover and execute a provider from ambient credentials or an untrusted project directory implicitly.
10. Falling from a local provider to a cloud provider MUST never happen silently. It requires an
    explicitly enabled profile and MUST be reported to the caller and log.
11. Providers MUST declare relevant limits, including state/question budget, option count, parallel
    question support, supported primitives and language, and whether inputs leave the machine.
12. Before using a remote provider, Wrangle MUST make its data-egress boundary inspectable: provider,
    endpoint class, and the categories of normalized state that may be sent. Pixels and secret fields
    remain excluded.
13. The core MUST support hierarchical decisions for providers with small input budgets rather than
    silently truncating candidates. The decomposition is provider- and action-space-dependent and
    MUST be recorded in run evidence.
14. A hierarchy MUST preserve a detectable path to every candidate or report that coverage was
    reduced. A heuristic shortlist may not silently make candidates unreachable.
15. The first provider benchmark MUST exercise at least one local Jev-compatible model on Eric's
    Apple Silicon Mac through the same protocol used in production. Candidate selection is
    intentionally open because this model ecosystem is changing quickly.
16. No local model may become an automatic execution default based only on its published benchmarks.
    Each candidate must be evaluated on recorded Wrangle decisions for correctness, calibration,
    selective coverage, safety false negatives, latency, and memory use. A policy profile MUST define
    the measured threshold required before that provider may authorize mutation.

### 6. Run loop and verification

1. A run MUST have a goal, scope, action budget, timeout, provider identity, driver identity, policy
   profile, and explicit execution permission.
2. Multi-part work MAY use ordered plans without returning control to the calling agent between every
   action.
3. Stale decisions, second looks, and verification SHOULD consume bounded retry/spin allowances rather
   than silently exhausting the action budget.
4. The run MUST detect repeated no-ops, repeated identical actions, unchanged state, and bounded lack
   of progress.
5. `DONE` is a model claim, not proof. Wrangle MUST independently inspect available evidence before
   accepting it when the goal admits observable verification.
6. Consequential tasks SHOULD support task-specific verification stronger than generic model `DONE`.
7. The run MUST stop for missing literal text, required approval, ambiguous scope, low confidence,
   unsupported capability, stalled progress, delivery uncertainty, or exhausted bounds.
8. Waiting and settling MUST poll observed state rather than sleep for a guessed fixed duration.
9. Observation work SHOULD overlap decision or transition waits where doing so cannot weaken freshness.
10. Cancellation MUST stop new mutations promptly and leave an inspectable terminal event. If
    cancellation races an in-flight mutation and dispatch cannot be resolved, the receipt is
    `delivery unknown`; cancellation does not make it safe to retry.
11. Execution MUST provide an emergency stop that does not depend on the driving application retaining
    focus. Shutdown and crash recovery MUST release held keys, mouse buttons, and scope claims.

### 7. Machine interface and agent context

1. Compact, schema-versioned JSON events are the canonical machine interface.
2. Human terminal output MUST be rendered from those events. Integrations MUST NOT need to parse human
   prose.
3. The Pi extension MUST consume structured events directly and expose only the information needed for
   the agent's next decision. Progress MAY be shown in UI without entering the model's context.
4. Successful autonomous runs SHOULD return no more than about 250 tokens or 1 KiB to the calling
   agent, including outcome, verification, material actions, elapsed time, and run ID. CI SHOULD
   enforce the byte limit on representative successful results; integrations SHOULD additionally
   measure tokens with their active model tokenizer.
5. During normal progress, intermediate observations and action lists SHOULD remain inside Wrangle.
6. Output MUST be adaptive:
   - success returns a compact terminal result;
   - a recoverable stop returns the exact missing literal, approval, or narrowed ambiguity;
   - a failure includes only the recent evidence needed to choose a different strategy;
   - detailed history remains pull-on-demand by run and event ID.
7. Agent-facing output MUST NOT repeat unchanged page text, candidate lists, distributions, or timing
   tables.
8. The interface MUST support inspecting a run, one step, probabilities, scope history, and timing
   without injecting the whole trace into the current agent turn.
9. Stable terse keys and opaque IDs SHOULD be favored over repeated prose in machine events.
10. Typed literals MUST not be echoed in final output. Secure-looking values MUST be redacted from all
    events even though secure literals are otherwise refused.

Illustrative success event:

```json
{"t":"done","run":"01J…","proved":"receipt visible","acts":6,"ms":3800}
```

Illustrative handoff:

```json
{"t":"need","run":"01J…","kind":"literal","field":"Message"}
```

These examples are not a frozen schema.

### 8. Event log and replay

1. Every run MUST create a compact structured event log by default.
2. It MUST contain bounded normalized observations or deltas, decisions, selected probabilities,
   policy outcomes, action receipts, provider and driver identities, scope changes, and phase timings.
   Observed user content MUST be minimized to what the evidence needs.
3. It MUST NOT contain raw pixels, full repetitive text, passwords, secrets, or typed literal values.
4. The log MUST preserve enough evidence to explain why an action was offered, selected, authorized,
   delivered, refused, or left uncertain without claiming that dispatch proves effect.
5. Default logs MUST be owner-readable only and expire automatically after seven days. Users MUST be
   able to clear, pin, or export a run explicitly.
6. Provider benchmarking MAY require an explicit richer capture mode. That mode MUST disclose its
   additional content and retention before the run.
7. Logs MUST never overwrite an earlier run and SHOULD support deterministic offline replay of policy
   and output shaping even when perception cannot be replayed.

### 9. Driver capabilities and assurance

1. Every driver MUST publish capabilities and assurance properties before attachment, including:
   - supported scope kinds;
   - perception sources;
   - target identity strength;
   - supported action classes;
   - mutation delivery/readback guarantees;
   - text readback support;
   - whether capture or extra permissions are required.
2. The core MUST prefer the strongest applicable driver when more than one can control a surface.
3. Changing to a lower-assurance driver MUST be explicit and logged.
4. A generic desktop driver MUST not claim DOM-equivalent freshness for an OCR rectangle.
5. Driver-specific implementation dependencies are acceptable during alpha. The driver contract MUST
   be versioned and language-neutral, but whether every driver runs in or out of process is deferred
   until the macOS spike measures the tradeoffs.
6. Drivers MUST be explicitly installed or configured. Wrangle MUST NOT load executable driver code
   implicitly from an untrusted project directory.

#### macOS driver

The macOS driver is the first redesigned driver. It combines Accessibility, local ephemeral capture,
OCR when needed, window/process identity, and deterministic input. It must support native AppKit and
Electron applications, report partial trees honestly, and keep coordinate fallback subordinate to
scope and geometry revalidation.

#### Browser drivers

Browser support will share a browser capability model rather than create three unrelated policy
loops. Safari, Chromium, and Gecko MUST support the same scope, observation, receipt, and policy
meanings even when their platform transports differ.

Dedicated automation profiles and attachment to ordinary user windows are both valid modes. An
optional browser extension is acceptable for ordinary-window attachment, but its exact messaging
architecture is deferred. Extension permissions MUST be least-privilege and visible, and selecting one
tab MUST NOT authorize unrelated tabs. The mode, ownership, profile boundary, and assurance level must
be visible. Browser DOM drivers should supersede the generic desktop driver when available.

#### Linux drivers

Linux desktop work begins with Wayland. Browser drivers may arrive before general desktop support.
The future desktop driver is expected to use accessibility and portal-mediated capture/input where
available, but exact APIs are deferred until that milestone.

### 10. CLI and Pi integration

1. The CLI is the durable user-facing engine interface. Its primary computer-use command accepts one
   natural goal and application name and owns the bounded loop and cleanup.
2. The Pi extension is a thin integration, not a second implementation of scope, policy, or the run
   loop. A normal desktop request MUST require only one Pi tool call.
3. The natural task tool is an explicit execution boundary for necessary non-consequential actions.
   Low-level debug interfaces remain preview-first, and consequential dispatch requires a separate,
   artifact-bound approval.
4. The CLI MUST support the single-task interface plus listing drivers/providers and their
   capabilities, selecting scopes, observing, planning, running, stopping, closing, and inspecting
   stored evidence.
5. Agent instructions MUST direct agents to use the CLI/tool interface rather than writing scripts
   against internal classes.
6. Human output may be richer than agent output but MUST preserve the same meanings and terminal
   outcomes.

## Acceptance criteria

### Hard release gate: safety and scope

The first whole-Mac alpha does not ship unless the automated and live acceptance suite demonstrates:

1. No action lands outside the selected scope.
2. A stale or replaced target is refused before dispatch.
3. A mutation with uncertain delivery is never retried.
4. A delivered or potentially delivered action is recorded before a failed subsequent observation can
   obscure it.
5. A handed-over window is not closed by session shutdown.
6. A lower-assurance driver or cloud provider is never selected silently.
7. A consequential action reaches policy before dispatch.
8. Password or secret values never enter provider state, agent output, or the event log.
9. Screenshots are neither transmitted nor persisted without explicit opt-in.
10. Missing permissions, partial perception, and ambiguous scope fail closed rather than masquerading
    as an empty or complete observation.
11. Overlapping exclusive sessions cannot mutate the same scope, and detected human interference
    invalidates a pending action.
12. Emergency stop and crash cleanup leave no held input or stale scope claim.

Safety and scope correctness are the hard release gate, but doing nothing is not a passing product.
The controlled representative scenarios below MUST also complete successfully. Broader task-completion
rate, latency, and context use remain measured objectives rather than release thresholds. The
executable application profiles and host/VM boundary are maintained in the
[macOS compatibility matrix](evaluations/macos-app-compatibility.md).

### Representative acceptance scenarios

#### Finder and file dialogs

- Attach by list ID, frontmost countdown, and interactive picker.
- Distinguish two Finder windows with similar titles and act only in the selected one.
- Navigate a disposable fixture directory with accessibility actions.
- Select a known file in an Open dialog without interacting with another application's window.
- Run all mutating file scenarios only against disposable fixtures, never the user's real files.
- Refuse a candidate after its row or window is replaced.

#### System Settings

- Locate and report a known setting without changing it.
- Preview a reversible setting change.
- Execute that change only under a profile that permits it.
- Ask or refuse before changing a security, privacy, or application-permission setting.

#### Slack and Teams

- Detect the minimal Electron accessibility stub.
- Apply `AXManualAccessibility=true` to the current PID and verify a useful tree appears.
- Navigate to a dedicated test-workspace fixture conversation.
- Place one exact ASCII literal and one exact Unicode literal in the composer, each exactly once.
- Reobserve and verify the complete field value using a fresh ref.
- Leave the draft unsent under preview/default policy.
- Route Send through consequential-action policy before execution.
- Reapply accessibility enablement after an application restart.

#### Scope drift and delivery

- Move focus to an unrelated app while a decision is pending and prove the action cannot land there.
- Inject human pointer or keyboard input while an action is pending and prove exclusive mode pauses or
  stops while cooperative mode invalidates and reobserves.
- Start overlapping sessions at surface, application, and desktop levels and prove exclusive mode
  prevents concurrent mutation.
- Open a sheet, menu, or dialog belonging to the scoped window and prove it remains attributable.
- Open an unrelated root surface and prove it requires scope expansion.
- Move the scoped window between displays with different origins or scale factors and prove old
  coordinate candidates are refused.
- Kill a driver before dispatch, during dispatch, and after dispatch; distinguish not-delivered from
  delivery-unknown and prove uncertain dispatch is never retried.
- Prove a delivered action with no observed effect is recorded as delivered/unchanged rather than
  delivery-unknown or successful effect.

#### Output and evidence

- A normal successful run returns approximately 250 tokens and no more than 1 KiB to the calling
  agent.
- Unchanged observations do not repeat their full state.
- A missing literal response contains the field identity and accepted recovery, not the surrounding
  tree.
- A policy approval request identifies one pending action without dumping the observation.
- `inspect` can recover detailed decisions, timings, and receipts from the run ID.
- The default run directory contains no images and no literal values, is owner-readable only, and is
  removed after seven days unless pinned.

#### Decision providers

- The same recorded choices can be evaluated through TypeSafe Jev and any conforming local provider.
- A malformed distribution, missing option, invalid confidence, timeout, or dead provider fails closed.
- Local provider failure does not contact Jev unless cloud fallback was explicitly enabled.
- Hierarchical choice reports reduced coverage rather than silently truncating unreachable candidates.
- A remote provider run identifies its egress boundary before sending normalized state.
- A provider below its policy profile's measured mutation threshold may preview but cannot execute.

## Measurements

Every live run and acceptance run SHOULD report these measurements without making the normal
agent-facing response carry the full table:

### Safety and reliability

- out-of-scope actions;
- stale actions refused before dispatch;
- uncertain mutations retried;
- delivered actions by verified, unchanged, unverified, and not-applicable effect;
- consequential actions dispatched without policy;
- action readback/verification rate;
- concurrency interference and overlapping-scope conflicts;
- task completion and handoff reason;
- no-op and circling rate.

### Performance

- startup and attachment time;
- capture, AX traversal, OCR, merge, decision, policy, action, settle, and verification time;
- p50 and p95 steady-state step latency;
- changed screen area and OCR reuse rate;
- provider latency by question count and hierarchy depth.

There is no fixed step-latency release gate in the first alpha. The product should use the best
available path, preserve phase evidence, and prevent a slower fallback from becoming invisible.

### Agent efficiency

- schema bytes and active-model tokens returned on success, handoff, and failure;
- cumulative agent-facing output per completed task;
- number of agent round trips per task;
- count of full observations requested explicitly;
- duplicated unchanged content returned.

### Provider evaluation

- action-choice correctness on recorded Wrangle states;
- consequential and stale false-negative rates;
- confidence calibration and expected calibration error;
- accuracy at selective automation coverage thresholds;
- rate at which hierarchy excludes the correct target;
- Apple Silicon MPS latency and memory use;
- local-versus-cloud disagreement and fallback rate.

## Milestones

### M1: read-only macOS perception

- Scope listing and all three selection methods.
- Window/process identity and ownership.
- Multiple displays, mixed origins/scale factors, window movement, minimization, and Spaces.
- Accessibility traversal with explicit partial-coverage reporting.
- Automatic Electron accessibility enablement and verification.
- Ephemeral local capture and OCR.
- Provenance-aware merged candidates.
- Compact observations, deltas, timings, and event logs.

### M2: scoped macOS actions

- Initial bounded action set and exact literals.
- Revalidation, nonces, two-axis receipts, and delivery-uncertainty handling.
- Exclusive/cooperative concurrency, overlap prevention, focus drift, and child-surface attribution.
- Electron contenteditable readback.
- Driver-specific policy defaults and consequential-action handoff.
- Safety acceptance gate passing for Finder, Settings, Slack, and Teams.

### M3: autonomous runs and provider interchange

- Plans, budgets, settling, stall detection, and independent verification.
- Versioned TypeSafe and local-provider adapters.
- Hierarchical small-context decisions.
- Provider conformance suite and comparative replay benchmark on Apple Silicon.
- Adaptive agent output and pull-based inspection.

### M4: Pi integration

- Thin Pi extension consuming compact JSON events directly.
- Separate preview and execute tools or permissions.
- Approval and missing-input UX that does not dump state into context.
- Context-budget measurements on representative tasks.

### M5: browser family

- Common browser capability contract.
- Safari migrated to it without weakening current scope and delivery guarantees.
- Chromium and Gecko dedicated profiles.
- Optional least-privilege extension attachment for ordinary Chrome and Firefox profiles.
- Cross-browser acceptance tasks and assurance reporting.

### M6: Linux

- Browser drivers on Linux.
- Wayland-first desktop perception and control spike.
- Linux capability and permission reporting.
- Scope and delivery acceptance suite adapted to platform constraints.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Accessibility trees are incomplete or misleading | Preserve provenance, report caps/timeouts, combine local OCR, and never claim complete coverage silently. |
| Electron exposes only a stub | Set and verify `AXManualAccessibility` per PID; test Slack and Teams continuously. |
| Electron contenteditable reports false failures | Treat it as a separate capability and trust fresh value readback, never blind retry. |
| OCR regions lack stable identity | Restrict them to the pinned geometry, revalidate before dispatch, and report lower assurance. |
| A local model's published benchmark does not transfer | Replay real Wrangle decisions, measure calibration and safety errors, and gate automation by observed performance. |
| Hierarchical decisions hide the correct target | Make candidate coverage measurable and report reductions rather than truncating silently. |
| Rich traces leak user content | Store compact deltas, redact literal values and secrets, keep pixels ephemeral, and make richer capture explicit. |
| Driver fallback weakens safety | Publish capabilities and require explicit downgrade. |
| Cross-app desktop scope becomes implicit permission | Default to one root surface and route every root expansion through policy. |
| Human or another session moves focus between observation and dispatch | Use exclusive concurrency by default; invalidate pending actions on detectable interference. |
| Dispatch success is mistaken for task effect | Record dispatch and observed effect separately; never treat acceptance alone as verification. |
| Local logs retain private UI text indefinitely | Use owner-only compact logs with seven-day expiry and explicit pin/export. |
| Wayland limits capture or input | Treat capabilities as discoverable, fail closed, and avoid promising parity before platform evidence exists. |
| A language rewrite is optimized prematurely | Keep contracts language-neutral, measure phase cost, and decide the core language after profiling. |

## Decisions already made

| Question | Decision |
|---|---|
| First post-Safari milestone | Whole Mac before cross-browser expansion |
| Initial applications | Finder/file dialogs, System Settings, Slack, Teams |
| Product packaging | CLI engine plus thin Pi extension |
| Primary user | AI coding and assistant agents |
| Compatibility | Not required during alpha/design |
| Scope | Selectable root surface/application/desktop; desktop window or browser tab default |
| Concurrency | Selectable exclusive/cooperative policy; exclusive default |
| Window selection | List ID, frontmost countdown, and interactive picker |
| Mutation default | Preview by default; execution explicit |
| First action set | Core interactions plus deterministic navigation keys |
| Screenshot boundary | Ephemeral local capture; no provider pixels; no default persistence |
| Electron observation setup | Automatically enable `AXManualAccessibility` during preview and log it |
| Text generation | None; exact goal spans and literals only |
| Credentials | Password-manager/SSO UI only |
| Consequential actions | Configurable policy, with driver-specific defaults |
| Agent output | Adaptive; target about 250 tokens on success |
| Machine interface | Compact JSON events |
| Default evidence | Owner-only compact event log, seven-day expiry, no pixels or literal values |
| Provider architecture | Versioned out-of-process contract for executables, services, or HTTP adapters |
| Local provider strategy | Jev-compatible provider ecosystem; hierarchy for small contexts; benchmark candidates on Apple Silicon |
| Cloud fallback | Never silent |
| Browser attachment | Dedicated profiles and ordinary-window attachment; optional extension acceptable |
| Platform dependencies | Acceptable during alpha |
| Core language | Prototype and measure before deciding |
| macOS alpha target | Eric's current macOS release on Apple Silicon |
| Linux direction | Wayland first |
| Existing project | Evolve `wrangle` in place |
| Hard alpha gate | Safety and scope correctness |

## Deferred architecture decisions

The PRD intentionally leaves these for evidence-backed ADRs:

- whether the long-lived core remains Ruby or moves to another language;
- JSONL, sockets, JSON-RPC, or another framing beneath the compact JSON event model;
- whether each driver is in-process or isolated behind a process boundary;
- the macOS OCR and image-diff implementation;
- native helper build and distribution;
- exact driver discovery and package installation conventions;
- browser extension attachment and messaging topology;
- Chromium and Gecko dedicated transport choices;
- Linux accessibility, capture, and input bindings;
- cleanup scheduling and pinned/exported run storage mechanics;
- the exact event schema and protocol-version negotiation;
- policy profile syntax and initial driver thresholds.

## Background and prior art

Wrangle 0.1 proves scoped Safari observations, guarded actions, delivery resolution, Jev-driven plans,
and compact change reporting. This redesign keeps those invariants while removing Safari assumptions
from the product boundary.

Relevant prior art includes:

- Electron's documented `AXManualAccessibility` opt-in and Chromium's on-demand accessibility tree;
- the native Finder, Settings, and Slack acceptance findings for tree enablement and Electron
  `contenteditable` behavior;
- `jev-use` for keeping the AX read/typed-choice/act/check loop behind one natural task interface;
- `typesafe-computer-use` for merged AX/OCR provenance, bounded tree walking, changed-region OCR, and
  focused-field state;
- `mobile-jev` for fresh-target validation, record-before-observe, exact-span typing, and refusing to
  retry uncertain mutations;
- `pi-warden` and `foreman` for keeping semantic assessment separate from deterministic policy;
- Laya, SemIf, jevlike, NanoJev, openjev-sglang, and other emerging local typed-decision engines as
  examples of why the provider boundary must remain model-neutral.

Prior art informs requirements but does not override Wrangle's scope, privacy, text, or context
constraints.
