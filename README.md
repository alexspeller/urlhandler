# URLHandler

A macOS default-browser replacement that routes each clicked `http`/`https` link to the right
browser — and the right **Chrome profile** — based on rules you write in JavaScript. When a link
is ambiguous it shows a small keyboard-driven chooser.

- **Routing is code.** Rules live in `~/.config/urlhandler/rules.js` as a global
  `async function route(url, ctx)`. Reloaded automatically on save — no rebuild, no restart.
- **Async-aware.** A rule can `await resolve(url)` to follow redirects (link shorteners) or
  `unwrap(url)` to decode trackers (Slack, SafeLinks, …) before deciding.
- **Fast.** Runs as a resident background agent (`LSUIElement`), so there's no per-click launch
  cost. It can launch at login so even the first click after a reboot is instant.
- **Chooser.** Ambiguous links open a small popup: press `1`–`9` to pick, `⌘C` to copy the URL,
  `esc` to cancel. It won't grab your keyboard mid-sentence or vanish under a stray click: it waits,
  dimmed, until you've stopped typing (~1.5 s) and clicking elsewhere (~1 s) — or until you click it
  (clicks on it are ignored for its first second). Links that arrive while it's open queue up behind it.

## How it works

When set as the default browser, macOS sends every clicked URL to the app via the GetURL Apple
Event. The agent runs your rules, then either opens the chosen browser/profile directly or shows
the chooser. The browser/profile inventory is data (`config.json`); the decision logic is code
(`rules.js`).

## Requirements

- macOS 13+ (built/tested on macOS 26).
- Swift toolchain (Xcode or Command Line Tools — `xcode-select --install`). No Xcode app required.

## Build & install

```sh
make app          # build + assemble + ad-hoc sign build/URLHandler.app
make install      # install to /Applications and register with LaunchServices
make set-default  # register as default http/https handler (macOS shows a confirmation prompt)
make login-item   # launch the agent at login (recommended)
```

`make install` seeds `~/.config/urlhandler/{config.json,rules.js}` on first launch if missing.
Override the install location with `make install PREFIX=~/Applications`.

## Configuration — `~/.config/urlhandler/config.json`

JSON (with `//` and `/* */` comments). The browser/profile inventory plus chooser settings:

```jsonc
{
  "browsers": {
    "personal": { "app": "Google Chrome", "profile": "Default" },
    "work":     { "app": "Google Chrome", "profile": "Profile 1" },
    "safari":   { "app": "Safari" },
    "firefox":  { "app": "Firefox", "profile": "work" }
  },
  "default": "personal",                          // used if a rule names an unknown browser
  "prompt": ["personal", "work", "safari"],       // shown in the chooser, in order (keys 1..n)
  "resolveTimeoutSeconds": 5                       // max wait when a rule calls resolve()
}
```

- `app`: application name (`"Google Chrome"`), bundle id (`"com.google.Chrome"`), or absolute path.
- `profile`: Chrome on-disk profile directory (`"Default"`, `"Profile 1"`) or Firefox profile name.
  Run `urlhandler list-profiles` to see Chrome's directory names mapped to display names.
- `args` (optional): extra command-line arguments for the browser.

## Rules — `~/.config/urlhandler/rules.js`

Define a global `route(url, ctx)` (sync or `async`):

```js
async function route(url, ctx) {
  url = unwrap(url);              // decode Slack/SafeLinks/Google/Proofpoint trackers (no network)
  const u = new URL(url);

  if (ctx.opener?.bundleId === "com.tinyspeck.slackmacgap") return { browser: "work", url };

  if (["t.co", "bit.ly"].includes(u.hostname)) {            // follow shorteners (network)
    try { return route(await resolve(url), ctx); }
    catch (e) { return { prompt: true, url }; }
  }

  if (u.hostname.endsWith("github.com")) return { browser: "work", url };
  return { prompt: true };
}
```

**`ctx`** — `{ opener: { bundleId, name } | null, browsers: [keys], default: key }`. `opener` is the
app that opened the link (e.g. Slack, Mail).

**Return** — `{ browser: "<key>" }` to open in that browser, optionally with `url` to rewrite the
target; `{ prompt: true }` (or nothing) to show the chooser.

**Globals** — `resolve(url)` (async redirect-follower), `unwrap(url)` (local tracker decode),
`console.log/warn/error`, `URL`, `URLSearchParams`.

### Hot reload

Editing `config.json` or `rules.js` reloads automatically (FSEvents watch + an mtime check before
each route). Reloads are **safe**: a syntax error or malformed JSON keeps the last-good version and
surfaces the error in the menu bar and `agent.log`, so a typo never breaks routing.

## Command line

Useful without being the default browser (great for testing rules):

```sh
urlhandler route <url> [--from <bundleid>]   # print the routing decision as JSON (doesn't open)
urlhandler open  <url> [--from <bundleid>]   # route and open
urlhandler resolve <url>                     # follow redirects, print the final URL
urlhandler list-profiles                     # Chrome profile directory names for config.json
urlhandler set-default                       # register as default http/https handler
urlhandler login-item [register|unregister|status]
```

With no arguments it runs as the resident agent (how macOS launches it).

## Menu bar

A menu-bar item provides: Set as Default Browser, Open Config Folder, Reload Config & Rules,
Launch at Login (toggle), Quit, and a live reload-status line (errors shown here).

## Logging

The agent writes a tailable log to `~/.config/urlhandler/agent.log` (truncated each launch) and to
the unified log (`log stream --predicate 'subsystem == "com.alexspeller.urlhandler"'`).

## Development

```sh
swift build                    # build
make test                      # run the self-test suite (swift run urlhandler-selftest)
make restart-agent             # relaunch the installed agent after a rebuild
```

Layout: `Sources/URLHandlerKit` (library: JSEngine, ConfigStore, Resolver, Launcher, Router,
Chooser, Agent, …), `Sources/urlhandler` (executable entry), `Sources/urlhandler-selftest` (tests).

### Notes

- The app is **ad-hoc signed** (no Developer ID needed for local use). This is sufficient to be the
  default browser, receive Apple Events, and register a login item.
- Setting the default browser shows a macOS confirmation prompt (system-enforced for http/https).
- Rules run in JavaScriptCore. A bare context has no `URL`/`console`/`fetch`; those are provided by
  a small prelude (`URL` is backed by Foundation's `URLComponents`).

## License

[MIT](LICENSE) © Alex Speller
