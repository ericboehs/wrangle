---
name: wrangle
description: Drive a real Safari window from the shell - open a page, see what it offers, click, type, and read results back. Use for looking things up on sites that need a real logged-in browser (flights, prices, dashboards, portals), filling a web form, or when the user says "use my browser", "check this site", or "/wrangle". Not for fetching static pages; use a normal HTTP fetch for those.
compatibility: macOS with Safari, and `wrangle` on PATH. Requires Safari > Settings > Advanced > "Allow JavaScript from Apple Events", plus a one-time Apple Events permission prompt.
---

# Wrangle

Drive one real Safari window through a persistent session. Every command below is a shell command.

**Never write a Ruby script for this.** The CLI is the entire interface. If you catch yourself
writing `require "wrangle"`, stop — use `wrangle observe` and `wrangle act` instead.

## The loop

```bash
wrangle open "https://example.com" --display 1 --settle 8   # start; prints the first observation
wrangle observe --match 'passenger|search'                  # look, filtered
wrangle act 13                                              # do one thing, see what changed
wrangle text --match 'total|price'                          # read page content
wrangle close                                               # always finish here
```

The session lives in a background process, so these are separate commands against the same window.
State persists between them. Use `--session NAME` to run more than one at a time.

## Reading the output

```
acted   click "Add adult"
page    "Oklahoma City to Denver | Google Flights"  <https://...>
state   9f8aab03117c  scroll 0/1623  1193 chars  72 actions
changed url changed, text +1114
  appeared    "Remove adult", "2 passengers"
  gone        "Add adult", "Done", "Cancel"
   13  click   button    2 passengers
```

- **`appeared` / `gone` is your feedback signal.** `"Remove adult"` appearing proves the count went
  1 → 2. Check it after every action instead of re-reading the whole page.
- **`changed nothing — the page is byte-identical`** means your click did nothing. Do not repeat it.
  Observe, and pick a different action.
- **The numbers on the left are refs, and they shift after every action.** Only ever use a ref from
  the most recent output. A stale ref is refused, not silently mis-clicked.

## Finding the right action

`observe` truncates to 25 actions. Do not dump everything; filter:

```bash
wrangle observe --match 'passenger|adult|done'   # regex, case-insensitive
wrangle observe --all                            # everything, when you must
```

To read page content rather than controls:

```bash
wrangle text                       # whole page text
wrangle text --match '\$[0-9]'     # only matching lines
```

## Typing and waiting

```bash
wrangle act 7 --text "Lisbon"      # a fill action needs --text
wrangle act 4 --settle 10          # wait longer for a slow update
```

`--settle` polls until the page stops changing, up to N seconds. It does not sleep blindly. Raise it
for searches and slow SPAs. If content looks half-loaded — placeholders, "Fetching results", counts
that disagree with each other — that is a settle problem: run `wrangle observe --settle 10` again
before concluding anything.

## Let Jev drive a whole sub-task

`wrangle run` decides and acts in a loop, using a small typed-choice model (Jev) that picks one of the
actions Wrangle observed. It is several times faster than stepping by hand, because it never waits for
you between clicks.

```bash
wrangle run --goal "Search flights: from OKC to DEN, depart 2026-10-12, return 2026-10-15." \
  --literal 'where from=OKC' --literal 'where to=DEN' --steps 10 --execute
```

- `--execute` is required. Without it the loop only proposes.
- `--literal LABEL=VALUE` supplies text for a field whose label contains `LABEL`. **The model never
  invents text.** If a fill has no matching literal, the run stops and asks you for it.
- `--steps N` caps the loop. `--min-confidence F` moves the bar (default 0.5).

### When it hands back to you

The run stops and prints `ask` when Jev is not confident enough, when a fill needs text, or when it
notices itself circling. **You are the fallback.** Do not just re-run the same goal — look, then either:

1. Re-run with a **narrower goal** naming the next concrete step ("The calendar is open; click
   Thursday, October 15, 2026, then click Done"). This is usually right.
2. Verify the state yourself with `wrangle observe` / `wrangle text`, then `wrangle act REF` directly.
   Do this when Jev names the right control but is unsure whether to act at all.

Narrow goals work far better than one big goal. Drive a form in legs: airports, then dates, then
passengers, then submit.

## Prefer a deep link over filling a form

If the site accepts search parameters in the URL, open that directly and skip the form entirely. One
`open` beats six `act`s and cannot mis-click. **Unless the user asked you to use the site's own UI** —
then fill the form with `wrangle run` and do not shortcut it. Example:

```bash
wrangle open "https://www.google.com/travel/flights?q=Flights%20from%20OKC%20to%20DEN%20on%202026-10-12%20through%202026-10-15" --settle 8
```

Then use `act` only for what the URL could not express.

## Windows

```bash
wrangle windows --titles    # what Safari has open
wrangle displays            # screen geometry for --display
```

- `wrangle open URL` creates a window Wrangle owns and will close.
- `wrangle attach WINDOW_ID` takes over a window the user already has open. **Ask first.** Wrangle
  never closes or navigates an attached window, but it will scroll and click in it.
- Use `--display 1` (a second monitor) when available so you are not covering the user's work.

## When something fails

Exit codes: `0` ok, `2` usage, `3` stale — observe and retry, `4` the session is over, `5` no session.

| Message | What to do |
|---|---|
| `StalePage: Page changed since this decision` | `wrangle observe`, then act on a fresh ref. Normal. |
| `ScopeLost: ...` | Terminal. The user took their window back, or it gained a tab. Do not reopen without asking. |
| `DeliveryUnknown: ...` | Terminal. An action may or may not have landed. **Never repeat it.** Tell the user what is uncertain. |
| `No action #N in the last observation` | You used a stale ref. Observe again. |
| `N Safari processes are running` | Orphaned `safaridriver` instances. Ask the user before killing anything. |

## Rules

- One action per command when stepping by hand. Observe between actions.
- Prefer `wrangle run` for a multi-step sub-task; step by hand when it hands back to you.
- Never repeat a mutation to find out whether it worked — read the page instead.
- Never enter passwords, card numbers, or 2FA codes. Stop and hand back to the user.
- Do not buy, book, send, post, or delete anything without explicit confirmation of that exact step.
- `wrangle close` when you are done, even if the task failed.
- Report what you actually observed. If a value looks inconsistent, say so rather than smoothing it.

## Worked example

Flight prices, OKC → DEN, Oct 12–15, 2 adults, filling the site's own form. **One command drives the
whole form.** Hand-stepping this same task took ten separate commands and over two minutes, almost
all of it your own turn latency.

```bash
wrangle open "https://www.google.com/travel/flights" --display 1 --side left --settle 4

wrangle run --execute --steps 40 --min-confidence 0.4 \
  --literal 'where from=OKC' --literal 'where to=DEN' \
  --plan "Set the origin to OKC and the destination to DEN, choosing the matching airport from each autocomplete list." \
  --plan "Open the Departure field to show the calendar, then click the day Monday, October 12, 2026." \
  --plan "Click the day Thursday, October 15, 2026 for the return, then click Done to confirm the dates." \
  --plan "Open the passenger selector, add a second adult, then click Done to confirm." \
  --plan "Click the Search button to run the flight search." \
  --expect 'taxes \+ fees for 2 adults'
```

```
== 4. Open the passenger selector, add a second adult, then click Done to confirm.
26. did   1 passenger                    (91% sure/100% target, jev 272ms, step 626ms)
27. did   Add adult                      (95% sure/95% target, jev 318ms, step 458ms)
28. done  DONE                           (53% sure, jev 342ms)
proven  the page shows "taxes \+ fees for 2 adults"
```

Then read the result and finish:

```bash
wrangle text --match 'Nonstop|^\$|2 adults'
wrangle close
```

If a leg hands back, do not re-run the same plan. Look at the page, then re-run **only the remaining
legs**, with the first one describing what you actually see:

```bash
wrangle run --execute --min-confidence 0.4 \
  --plan "A passenger dialog is open. Click its Done button to close it." \
  --plan "Click the Search button to run the flight search."
```

## Rules of thumb for plans

- One concrete step per leg. "Click the day Monday, October 12, 2026" beats "pick the dates".
- Name the control the way the page labels it. The model is choosing from observed labels, not guessing.
- Legs are ordered and assumed: a leg that fails ends the plan, because the rest depend on it.
- `--expect RE` proves the outcome from page text. Use it — a plan that ran is not a plan that worked.
- Lower `--min-confidence` to ~0.4 when you have written explicit legs; keep the default otherwise.
