# wrangle

**Hand one Safari window to a program, and no more than that.**

Wrangle drives an ordinary Safari window through Apple Events. There is no automation session, no
extension, and no native helper — so the window stays a real one you can see, keep, and take back at
any moment. It is pure Ruby with **no runtime dependencies**: everything it needs ships with Ruby and
macOS.

The usual way to automate Safari is `safaridriver --enable`, which gives you a quarantined browser
with a banner across the top, none of your cookies, and none of your sessions. That is the right tool
for testing a site. It is the wrong tool for doing something *in* a browser you are already logged
into. Wrangle is for the second case.

```ruby
require "wrangle"

Wrangle::Safari.open("https://example.com", display: 1) do |session|
  page = session.observe
  link = page["actions"].find { |a| a["label"] == "Learn more" }
  session.act(link, page)
  puts session.observe["title"]   # => "Example Domains"
end
# the window Wrangle opened is closed here; a window you handed it never would be
```

## Install

```ruby
gem "wrangle"
```

Requires macOS, Safari, and Ruby 3.2+. You also need two things switched on once, by hand:

- **Safari → Settings → Advanced → Allow JavaScript from Apple Events.**
- The first run raises an Apple Events permission prompt. Approve it, or find it later under
  **System Settings → Privacy & Security → Automation**.

Wrangle will not change either setting for you.

## Two ways in

**A window Wrangle opens.** It owns this one, so it may close it.

```ruby
session = Wrangle::Safari.open("https://example.com", display: 1)
session = Wrangle::Safari.open("https://example.com", bounds: [0, 0, 1200, 900])
```

**A window you hand over.** Already open, already signed in, already where you left it. Wrangle will
never close it and never navigate it.

```ruby
Wrangle::Safari.windows(titles: true)
# => [{"window_id"=>26081, "tabs"=>4, "display"=>0, "title"=>"Home / X", ...}]

session = Wrangle::Safari.attach(window_id: 26081)
```

Titles and URLs identify a tab to whoever owns it, so `windows` omits them unless you ask.

## Observing

`observe` returns one snapshot of the scoped tab:

```ruby
page = session.observe

page["url"]         # "https://example.com/"
page["title"]       # "Example Domain"
page["text"]        # visible text, capped at 6000 characters
page["scroll"]      # {"y" => 0, "height" => 997}
page["fingerprint"] # sha256 over url + text + actions + scroll
page["actions"]
# [{"id"=>"e1", "kind"=>"click", "node"=>1, "role"=>"link", "label"=>"Learn more",
#   "rect"=>{"x"=>384, "y"=>227.2, "w"=>82, "h"=>18.8}, "value"=>""},
#  {"id"=>"wait", "kind"=>"wait", "label"=>"Wait for the page to update"}]
```

The five action kinds are `click`, `fill`, `select`, `scroll`, and `wait`. A `select` is expanded into
one candidate per option, so choosing an option means choosing an action rather than supplying a
string the page never offered.

## Acting

```ruby
session.act(action, page)                    # click, select, scroll, wait
session.act(action, page, text: "Lisbon")    # fill
session.fresh?(page, action)                 # check without mutating
```

`act` takes the action **and** the observation it came from. That pairing is the whole point: an
action must be an exact candidate from a page that is still the page you saw.

## What it refuses to do

This is the interesting part. Wrangle fails closed, and every refusal below is a distinct exception
rather than a return value you can forget to check.

**It will not act on an action you made up.** An action must be an exact, unambiguous candidate from
the observation you pass alongside it. Change one field — a node id, a value — and it raises
`ArgumentError` without dispatching anything. If two candidates share an id, it refuses rather than
picks. This is the boundary that keeps model output from becoming instructions: a decision may only
name something the page was just seen to offer. Model output never becomes JavaScript, a selector, a
coordinate, a key command, or an option value that was not observed.

**It will not act on a page that moved.** Before every mutation, Wrangle re-checks the target: a
`guard` for clicks and selects, a `marker` for fills and scrolls. If the page shifted between your
observation and your decision, you get `StalePage` and nothing was dispatched. Observe again.

**It will not lose track of which window it was given.** Scope is one window id, one tab position, one
expected URL, and one document epoch. If the window you handed over gains a tab, or a different tab
becomes current, or a handed-over tab replaces its document, you get `ScopeLost` — and the session is
finished. It does not search for a replacement window, because the window it was given is the only
window it was given. A window Wrangle opened *is* allowed to navigate; a window you lent it is not.

**It will not retry a mutation to find out whether it landed.** Every action carries a nonce and the
page records a phase against it. If the reply goes missing, Wrangle reads the nonce back and resolves
what actually happened. It never repeats the action. If the outcome still cannot be established you
get `DeliveryUnknown`, the session is poisoned, and — since it can no longer describe what it would be
closing — it leaves the window open.

**It will not close a window it did not open.** `attach` sessions never close anything. Even an owned
window is left alone if it gained tabs in the meantime.

**It will not start when window ids are ambiguous.** Window ids are only unique within one Safari
process, and `safaridriver` is fond of leaving extra ones behind. More than one running Safari and
Wrangle refuses to start, rather than address the wrong browser. Override with
`allow_multiple_safari: true` if you know what you are doing.

```ruby
Wrangle::Error            # base
├─ Wrangle::BridgeError   # the osascript bridge failed
│  ├─ Wrangle::BridgeTimeout
│  └─ Wrangle::BridgeCallError  # #code, #scope?
├─ Wrangle::ScopeLost        # terminal: the window/tab/document is not the one you gave
├─ Wrangle::DeliveryUnknown  # terminal: an action may or may not have landed
└─ Wrangle::StalePage        # recoverable: observe again
```

## Speed

Measured against a real Safari on an M-series Mac, median of five runs:

| Step | Time |
|---|---:|
| Start the bridge, open a window, bind the document | 718 ms |
| First observation | 34 ms |
| Subsequent observation | 33 ms |
| One action | 84 ms |
| Close | 140 ms |

So a decision loop costs about **117 ms per act-and-observe step**. For comparison, the same work over
Safari's MCP server measured 9,059 ms to start and 1,327 ms per action — roughly 12× the startup and
16× the per-action cost.

The reason is that an Apple Event costs about **17 ms flat**, no matter how much data it carries, so
the only optimisation that matters is sending fewer of them. A read costs two events (one scope guard,
one evaluation) and a mutation costs four. The page scripts are shipped once at startup instead of
~12 KB per call, unresolved specifiers are addressed rather than resolved, and nothing reads window
bounds on the hot path.

## CLI

```
$ wrangle windows --titles
   26081  display 0    4 tabs  Home / X
   33389  display 1    1 tab   Are we the Krell? - YouTube

$ wrangle displays
0  x=0       y=31      1440x2529
1  x=-1920   y=351     1920x1080
```

## Interactive sessions

A browser session is only useful if it survives between commands, and a shell gives you one process
per command. `wrangle open` starts a background server holding one window behind a socket in
`~/.wrangle`, so every later command drives the same page.

```
$ wrangle open "https://www.google.com/travel/flights?q=Flights+from+OKC+to+DEN" --display 1 --settle 8
page    "Oklahoma City to Denver | Google Flights"  <https://...>
state   54da85dcabb5  scroll 0/1623  1218 chars  72 actions
   13  click   button    1 passenger, change number of passengers.

$ wrangle act 13
acted   click "1 passenger, change number of passengers."
changed text -1139
  appeared    "Add adult", "Add child aged 2 to 11", "Done", "Cancel"
  gone        "Change ticket type. Round trip", "Where from? Oklahoma City OKC"
    1  click   button    Add adult
    5  click   button    Done

$ wrangle act 1
acted   click "Add adult"
  appeared    "Remove adult"

$ wrangle text --match 'adult'
Prices include required taxes + fees for 2 adults.

$ wrangle close
```

Every action answers the only question that matters next: **what moved?** `"Remove adult"` appearing
is the proof the count went 1 → 2. When nothing moves, it says so outright — `changed nothing — the
page is byte-identical` — instead of leaving you to diff two page dumps.

The numbers are refs into the last observation and they shift after every action. Acting on a stale
one is refused rather than mis-clicked. `--settle N` polls until the page stops changing instead of
sleeping a guessed interval; without it you will read half-loaded pages and believe them.

| Command | |
|---|---|
| `open <url>` / `attach <id>` | start a session; `--display N`, `--session NAME` |
| `observe` | look; `--match RE`, `--all`, `--settle S` |
| `act <ref>` | one action; `--text STR`, `--settle S` |
| `text` | page text; `--match RE` |
| `status` / `close` | |

Exit codes: `0` ok, `2` usage, `3` stale (observe and retry), `4` the session is over, `5` no
session. Add `--json` to any command for the raw reply.

## Use it from an AI agent

`skills/wrangle` is an [Agent Skill](https://agentskills.io) teaching the loop above, so an agent
drives Safari with shell commands and never writes Ruby. For [pi](https://github.com/badlogic/pi):

```bash
pi package add git:github.com/ericboehs/wrangle
```

Or point any harness at `skills/wrangle/SKILL.md`.

## How it works

One `osascript -l JavaScript` process stays alive for the session and speaks newline-delimited JSON
over a pipe. Spawning it costs ~56 ms; talking to one that already exists costs ~0.3 ms.

Three pieces of JavaScript do the actual work. `bridge.js` runs in JXA and owns the Safari objects,
scope checks, and window lifecycle. `page.js` and `snapshot.js` run in the page: one installs the
document epoch and executes guarded actions, the other builds the observation.

Page requests are JSON, passed as a **single argument** to a fixed function that was installed at
startup:

```js
(pageScript)({"op":"act","action":{...},"nonce":"..."}, () => (snapshotScript))
```

Nothing a caller supplies is ever interpolated into the program's structure.

One honest caveat: actions are dispatched as synthetic DOM events. They are not OS-level trusted
input, and a page that checks `event.isTrusted` will know the difference.

## Limitations

- macOS and Safari only.
- No navigation API — to visit a different URL, open another window.
- No screenshots, no file uploads, no credential entry, no arbitrary JavaScript from the caller.
- Only one Safari process may be running.
- Observed page text is capped at 6000 characters; fill text at 2000.
- Requires *Allow JavaScript from Apple Events*, which is a real privilege. Grant it deliberately.

## Development

No bundle, no compiler, no native extensions:

```
rake          # test + node --check on the JavaScript (+ rubocop if installed)
rake test
```

RuboCop is optional and commented out of the `Gemfile`, because it wants a native `json` build and a
checkout should not need a working compiler.

The suite runs against a fake bridge subprocess that speaks the real protocol, so it exercises the
transport, the scope rules, and all four delivery-resolution outcomes without touching a browser.

## License

MIT. `lib/wrangle/js/snapshot.js` is vendored from
[browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) and used under the MIT
License, Copyright (c) 2026 Browser Use. See [LICENSE.txt](LICENSE.txt).
