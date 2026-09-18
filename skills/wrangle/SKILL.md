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

## Prefer a deep link over filling a form

If the site accepts search parameters in the URL, open that directly and skip the form entirely. One
`open` beats six `act`s and cannot mis-click. Example:

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

- One action per command. Observe between actions.
- Never repeat a mutation to find out whether it worked — read the page instead.
- Never enter passwords, card numbers, or 2FA codes. Stop and hand back to the user.
- Do not buy, book, send, post, or delete anything without explicit confirmation of that exact step.
- `wrangle close` when you are done, even if the task failed.
- Report what you actually observed. If a value looks inconsistent, say so rather than smoothing it.

## Worked example

Flight prices, OKC → DEN, Oct 12–15, 2 adults:

```bash
wrangle open "https://www.google.com/travel/flights?q=Flights%20from%20OKC%20to%20DEN%20on%202026-10-12%20through%202026-10-15" \
  --display 1 --settle 8 --match 'passenger'
#   13  click   button    1 passenger, change number of passengers.
wrangle act 13                  # appeared: "Add adult", "Done"
wrangle act 1                   # appeared: "Remove adult"  <- proof it is now 2
wrangle act 6 --settle 8        # "Done"; url changed, "2 passengers" appears
wrangle text --match 'adult'    # "Prices include required taxes + fees for 2 adults."
wrangle text --match '^\$'      # the fares
wrangle close
```
