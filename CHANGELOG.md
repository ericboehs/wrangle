# Changelog

## [Unreleased]

- `wrangle run --goal "..." --execute`: a decision loop driven by Jev, a typed-choice model that
  picks one of the actions Wrangle observed. It never writes text — `--literal LABEL=VALUE` supplies
  it, and a fill with no literal stops and asks.
- `--plan GOAL` (repeatable): ordered sub-goals advanced internally on DONE, so a whole form is one
  command instead of one agent turn per click. Measured on Google Flights: 29 steps in ~14s, against
  ten turns and 129s hand-stepping the same task.
- A confidence floor (`--min-confidence`, default `0.5`) that looks again once before handing back,
  because a page half-rendered when the model looked reads as ambiguity. `DONE` and `BLOCKED` are
  held to it too — an uncertain `DONE` still advances a plan, an uncertain `BLOCKED` must earn its
  handoff, since being wrong about them costs very different amounts.
- `--side left|right|top|bottom` parks the window on half a display.
- `--backend mcp` drives `safaridriver --mcp` instead of Apple Events: ~3ms per action against
  ~120ms, behind ~4s of startup, so it only pays off past roughly 28 actions. Experimental — its
  automation tab is backgrounded, and menus animated on `requestAnimationFrame` do not respond.
- `BLOCKED` is held to its own floor (0.6) that `--min-confidence` can raise but not lower, and a
  weak one gets two further looks with a widening pause before it is believed. A control that has
  not rendered yet is not a dead end, and lowering the floor to help an underconfident click should
  not make it easier to abandon the run.
- Every request carries a verification question — is this goal's outcome visible on the page? —
  answered independently of the one choosing actions, and read only to dispute a `DONE`. A confident
  disagreement keeps the leg working; an unsure one is ignored; one that survives three widening
  pauses hands back. `DONE` is the model reporting on its own work and it is optimistic: a plan
  reported success with a requested filter never applied.
- `UNPROVEN` in the transcript marks a claim that did not check out, and does not spend the budget.
- A dispute only ends a run when the leg it disputes has done nothing. A leg that acted is taken at
  its word once it has looked again: the verifier reads one snapshot, the actor knows what it did,
  and abandoning the remaining legs is the more expensive way to be wrong.
- A leg that has not acted yet cannot report `BLOCKED` without confirming it, however sure it is.
  A leg starts the instant the last one ends, so it often looks at a document that is still loading,
  and a half-loaded page does not read as ambiguous — it reads as definite, and reads surer the
  second time. Up to three further looks, widening to 2.5s.
- A second look appears in the transcript as `RELOOK` rather than being silently discarded.
- A `select` is no longer hit-tested before it runs. Styled dropdowns hide the native control under
  an overlay, which made Amazon's sort permanently unactionable; a select is driven by assigning
  value and dispatching input/change, so nothing depends on it being the topmost element.
- A blocked action says which of the four reasons stopped it — gone, read-only, scrolled out of
  view, or behind something else — instead of one message covering all of them.
- The step budget counts work done, not attempts made; stale retries and second looks no longer
  spend a leg's allowance, with a separate spin cap for loops making no progress.
- Waiting is an operation the model can choose rather than a fixed pause, and the settle poll starts
  impatient and backs off only when the page proves it is churning.
- The page is watched while Jev is thinking rather than before the request, so proving it has gone
  still is free: it fits inside a wait the step was making anyway. A rejected decision then has a
  fresh read already in hand and costs one more request instead of a request and a read.
- Fixed: the settle budget had never applied. The CLI always sent the key, so `fetch("steady", 0.2)`
  returned the `nil` that was there, `nil.to_f` is zero, and the backoff after a stale retry was
  multiplying that zero by two. No decision had waited for a page in months.
- A rejected decision says which part of the guard moved — the document, the route, the viewport, a
  field elsewhere, the target itself, or the content around it — instead of reporting that something,
  somewhere, changed.
- The route comparison drops the query string. Sites rewrite it constantly to hold state (a flights
  form puts the itinerary in `?tfs=` and rewrites it on every keystroke), and comparing the full URL
  rejected decisions about controls that had not moved. Removed that rejection reason entirely.
- A fill is checked against its target like a click, instead of falling back to the whole-page
  marker, which compares the title, every word of text and every action on the page.
- On the flights form: **0.67 wall seconds per decision, against 1.04**; a rejected decision costs
  428ms against 695ms; reading the page costs 38ms per decision against 120ms. The rejection rate
  barely moved (27% to 25%) — what remains is the page genuinely changing, and re-deciding is the
  right answer to that. Removing the retry backoff was tried and reverted: rejections went from 4.3
  to 7.3 a run.
- Unit tests for the three pieces that had only been covered through the loop: the action space, the
  decider, and the MCP bridge. The bridge's run against a fake `safaridriver --mcp` speaking real
  JSON-RPC over a real pipe, so a silent server, a dead one, and a document that took the installed
  runtime with it are all exercised rather than described. Nine deliberate mutations — folding
  actions by node, per-option select targets, the argmax and sum checks on a distribution, reading
  an unnamed head, retrying a mutation whose runtime vanished — were each confirmed to fail a test.

- Initial Safari backend: scoped windows, snapshot observations, guarded actions.
- Interactive sessions: a background server holds one window behind a socket in `~/.wrangle`, so
  `observe` and `act` are separate shell commands against the same page.
- Every action reports what moved — appeared/gone controls, text and scroll deltas, and an explicit
  "nothing changed" — so a caller can tell a click that worked from one that did not.
- `--settle` polls until the page stops changing rather than sleeping a guessed interval, and
  waits out a quiet floor first so a click that navigates is not mistaken for one that did nothing.
- Distinct exit codes separate "observe and retry" from "this session is over".
- `skills/wrangle`: an Agent Skill so an AI agent drives Safari by shell command, not by script.
- Fixed the test fixture emitting `scroll` as an integer where Safari emits `{y, height}`.
