# URLHandler — project guide for Claude

A macOS default-browser **router**: a resident background agent that receives every clicked
`http`/`https` URL (as the system default browser) and opens it in a chosen browser / Chrome
profile based on **JavaScript rules**. Ambiguous links show a small keyboard-driven chooser.
Replaces loshadki **OpenIn**. Pure Swift + SwiftPM; no Xcode required.

> This is a Swift/macOS project — the Ruby/JS/bundler/`httpx` guidance in the global CLAUDE.md does not apply here.

## Repository policy
This is a **personal repo**: Alex (working with Claude) is its only maintainer — no other contributors,
no reviewers. The policy is to **always keep it pushed to `main`** so it stays backed up: commit each
finished change straight to `main` and `git push` it. No feature branches or PRs. This overrides the
global "branch first / commit only when asked" defaults for this repository.

## Environment
- macOS 26, Swift 6.2 toolchain, **Command Line Tools only (no Xcode.app)**.
- The app is **ad-hoc signed** (`codesign -s -`) — sufficient to be the default browser, receive
  Apple Events, and register a login item. No Developer ID / notarization.

## Build / test / install (Makefile)
```sh
swift build            # debug build
make test              # run the self-test suite (NOT XCTest — see Testing)
make app               # release build + assemble + ad-hoc sign build/URLHandler.app
make install           # install to /Applications + register with LaunchServices
make set-default       # make URLHandler the default http/https browser (macOS shows a prompt)
make login-item        # launch the agent at login (SMAppService)
make restart-agent     # relaunch the installed agent
```
After `make install`, **restart the agent** (`make restart-agent`) to run the new binary. Config and
rules hot-reload at runtime, but the compiled binary does not.

## Testing — read this first
Tests are a **plain executable** at `Sources/urlhandler-selftest/`, run via `make test`
(`swift run urlhandler-selftest`). They are **not** XCTest (unavailable with CLT) and **not**
swift-testing (its standalone runner isn't wired up on a CLT-only macOS — `swift test` builds but
doesn't execute). Add checks to the `run*Tests(_:)` functions; a `Harness` records pass/fail and the
process exits non-zero on failure. The kit is a library target, so tests use the **public** API —
prefer integration-style checks over mocking. The highest-value tests are the JSEngine async bridge,
ConfigStore safe-reload, and the chooser's input hold.

Chooser tests drive a **real** `Chooser` through a test `ChooserEnvironment`: the panel is parked
offscreen at alpha 0, the keyboard clock is injected, and the focus steps (`takeFocus`/`returnFocus`)
are recorders — so the suite never shows a window, activates the process, or reads the developer's
own typing. Keep it that way. Timings are scaled down (0.1 s / 0.25 s); the suite is stable under full
CPU load. Never test ⌘C — it would overwrite the developer's clipboard.

## Architecture
SwiftPM package, three targets:
- `Sources/URLHandlerKit/` — library; all logic lives here.
- `Sources/urlhandler/main.swift` — thin entry; `runMain(argv)`: no args → resident agent, else → CLI.
- `Sources/urlhandler-selftest/` — the test executable.

Flow: click → macOS → **GetURL Apple Event** → `AppDelegate.handleGetURLEvent` → `Router.handle`
→ `JSEngine.route(url, ctx)` (runs the user's `rules.js`) → decision → `Launcher.launch` (open the
browser/profile) **or** `Chooser` (popup). It's a resident `LSUIElement` agent — no per-click launch.

### Key files (`Sources/URLHandlerKit/`)
- `Agent.swift` — `AppDelegate` (GetURL + `openFiles` handlers, menu bar), and `runAgent`/`runCLI`/`runMain`.
- `JSEngine.swift` — JavaScriptCore: runs `route(url, ctx)`; bridges native async `resolve` ↔ JS Promise.
- `Prelude.swift` — JS injected before rules: `console`, `URL`/`URLSearchParams` (Foundation-backed via `__parseURL`), `unwrap`.
- `ConfigStore.swift` — owns the current `Config` + `JSEngine`; FSEvents + mtime hot-reload; **safe** (keeps last-good on a bad edit).
- `Config.swift` — JSON models (+ a comment-stripping pre-pass).
- `Resolver.swift` — async URLSession redirect follower backing `resolve()` (HEAD→GET fallback, hard timeout).
- `Launcher.swift` — builds/runs the `open` command per browser/profile; re-activates the browser after a profile launch.
- `Chooser.swift` — NSPanel popup (1–9 pick, ⌘C copy, esc/close cancel). Appears **held**, goes **live**
  per `InteractionGrace`, **queues** URLs that arrive while it's up (see Gotchas). `ChooserEnvironment` is the test seam.
- `InteractionGrace.swift` — the hold's timing and every timing constant: ≥0.5 s, then until the keyboard
  counter reads 1.5 s idle and no click elsewhere for 1 s; clicks on the chooser blocked for 1 s.
  Ported from convenient-security's `PromptInteractionGrace`.
- `Router.swift` — orchestration; builds `ctx`; chooser/default fallbacks on error or unknown key.
- `Defaults.swift` — embedded default `config.json` + `rules.js`, seeded on first run. **Keep in sync with the live files.**
- `ChromeProfiles.swift` (Local State parsing), `LoginItem.swift`, `StatusItemController.swift`, `Logging.swift`, `CLI.swift`.

## Config & rules (runtime; hot-reloaded)
Live at `~/.config/urlhandler/{config.json, rules.js}`, seeded from `Defaults.swift` on first run.
- `config.json` — browser inventory (`key → {app, profile?}`), `default`, `prompt` (chooser order),
  `resolveTimeoutSeconds`. Seeded set: `personal` (Chrome Default), `work` (Chrome Profile 1),
  `safari`, `firefox` — a generic starter example users edit to match their own machine.
- `rules.js` — global `route(url, ctx)` (sync or `async`). Returns `{browser: key}` / `{browser, url}` /
  `{prompt: true}`. Helpers: `unwrap(url)`, `await resolve(url)`, `console`, `URL`. The seeded rules are
  a simple substring match on the lowercased URL (work hosts → work, personal hosts → personal, else chooser).

Editing either file hot-reloads instantly; a broken edit keeps the last-good version (error shown in the
menu bar + `agent.log`). **When changing default behavior, update the live files AND `Defaults.swift`.**

## Gotchas
- **JS context** has no `URL`/`console`/`fetch`/`setTimeout` — only what `Prelude.swift` injects.
- **All `JSContext`/`JSValue` access is main-thread.** URLSession completions hop to main before
  fulfilling JS promises (the native→JS→native async path depends on this; see `JSEngine`).
- **Swift 5 language mode is deliberate** (`Package.swift`): `JSValue`/AppKit aren't `Sendable`, and
  Swift 6 strict concurrency adds churn around JSC for no runtime benefit.
- **Chrome profiles require `open -n`** — without it the URL goes to the already-running Chrome's
  *current* profile and `--args` is silently dropped. `-n` loses activation, so `Launcher` re-activates
  via `open -a` on a short delay (this is why a clicked link can otherwise open behind the foreground app).
- **Two delegate paths, kept separate:** `http`/`https` arrive via the GetURL Apple Event (carries the
  opener PID → `ctx.opener`); local HTML files arrive via `application(_:openFiles:)`. Do **not** implement
  `application(_:openURLs:)` — it would also receive `http`/`https` and double-handle (and drop the opener).
- **The chooser must never take focus from someone mid-typing or mid-clicking.** Before this, it
  activated instantly: the next Return/digit of a sentence picked a browser, Esc cancelled, and the click
  back into the user's window dismissed it — ~17% of choosers ended with nothing opened, many re-clicked.
  Now it's ordered front **without** key/activation (held: rows dimmed, keys go to the user's app, clicks
  elsewhere can't dismiss it) and goes live after `InteractionGrace` — min 0.5 s, then keyboard counter
  (`CGEventSource.secondsSinceLastEventType`, no TCC grant) ≥ 1.5 s idle, and 1 s since the last click
  in another app (a global mouse monitor — needs no TCC grant; global *key* monitors do, so keys use the
  counter). **Clicks on the chooser (rows, close button) do nothing for 1 s after it appears or is held
  again** — in-flight clicks land on whatever it appeared over; after that a click engages it at once.
  A live chooser is **held again** (keyboard and mouse quiet doubled each time) on: a **stray key** (letter,
  space, ⌘+other… — focus goes back to the previous app; that key is lost, re-sending needs Accessibility);
  **losing focus within 2 s of going live**; or losing focus later **without** a click/key from the human in
  the last 1 s (another app — e.g. the browser just picked, cold-launching — took it). Only a pick, esc, ⌘C,
  the close button, or a later deliberate click-away ends it. A re-hold seeds its click quiet from the
  synchronous mouse counter, since the click that took the focus predates the new hold's global monitor.
- **URLs arriving while a chooser is up are queued** (FIFO; a URL already up or queued is ignored), shown
  `+N more`, each presented held afresh when the previous one ends. `dismiss()` drops the queue (logged).
  Every outcome is logged with ms timings (`showing chooser for`, `queued`, `chooser live at …`,
  `picked … by key|click`, `cancelled by esc|clicking away`, `closed`, `held again: <reason>`).
- `set-default` / `login-item` must run from the installed `.app` (they use `Bundle.main.bundleURL`); the
  Makefile targets invoke the installed binary.

## Debugging / verification
- `urlhandler route <url> [--from <bundleid>]` prints the decision JSON without opening anything;
  `urlhandler resolve <url>` follows redirects; `urlhandler list-profiles` lists Chrome profile dirs.
- Agent log: `~/.config/urlhandler/agent.log` (truncated each launch) — the **reliable** channel
  (`info`-level os_log isn't always persisted). Also `log stream --predicate 'subsystem == "com.alexspeller.urlhandler"'`.
- Deliver a GetURL event without being the default browser:
  `osascript -e 'tell application id "com.alexspeller.urlhandler" to open location "https://…"'`.
- GUI behaviors (chooser, focus/activation) need a real interactive session and can't be verified
  headlessly here — **don't pop windows or steal focus while the user is actively working**; ask them
  to confirm instead.
