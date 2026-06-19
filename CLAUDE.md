# URLHandler — project guide for Claude

A macOS default-browser **router**: a resident background agent that receives every clicked
`http`/`https` URL (as the system default browser) and opens it in a chosen browser / Chrome
profile based on **JavaScript rules**. Ambiguous links show a small keyboard-driven chooser.
Replaces loshadki **OpenIn**. Pure Swift + SwiftPM; no Xcode required.

> This is a Swift/macOS project — the Ruby/JS/bundler/`httpx` guidance in the global CLAUDE.md does not apply here.

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
prefer integration-style checks over mocking. The highest-value tests are the JSEngine async bridge
and ConfigStore safe-reload.

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
- `Chooser.swift` — NSPanel popup (1–9 pick, ⌘C copy, esc/defocus cancel). The pure `chooserKeyAction(...)` is unit-tested.
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
