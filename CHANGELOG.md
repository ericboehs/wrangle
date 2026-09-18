# Changelog

## [Unreleased]

- Initial Safari backend: scoped windows, snapshot observations, guarded actions.
- Interactive sessions: a background server holds one window behind a socket in `~/.wrangle`, so
  `observe` and `act` are separate shell commands against the same page.
- Every action reports what moved — appeared/gone controls, text and scroll deltas, and an explicit
  "nothing changed" — so a caller can tell a click that worked from one that did not.
- `--settle` polls until the page stops changing rather than sleeping a guessed interval.
- Distinct exit codes separate "observe and retry" from "this session is over".
- `skills/wrangle`: an Agent Skill so an AI agent drives Safari by shell command, not by script.
- Fixed the test fixture emitting `scroll` as an integer where Safari emits `{y, height}`.
