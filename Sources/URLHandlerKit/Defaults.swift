import Foundation

/// Default `config.json`, seeded into `~/.config/urlhandler/` on first run. This is a starter
/// example — edit it to match the browsers and Chrome profiles on your machine. Changes hot-reload.
/// Run `urlhandler list-profiles` to see your Chrome profile directory names.
public let defaultConfigJSON = #"""
{
  // Browsers you can route to. Keys are short names referenced by rules.js and the chooser.
  // "app": application name, bundle id, or absolute path.
  // "profile": Chrome on-disk profile directory ("Default", "Profile 1", ...) or Firefox profile name.
  //            Run `urlhandler list-profiles` to see Chrome profile directory names.
  "browsers": {
    "personal": { "app": "Google Chrome", "profile": "Default" },
    "work":     { "app": "Google Chrome", "profile": "Profile 1" },
    "safari":   { "app": "Safari" },
    "firefox":  { "app": "Firefox" }
  },

  // Opened when a rule returns a browser key that doesn't exist (and usable from rules via ctx.default).
  "default": "personal",

  // Browsers offered in the chooser popup, in order. Press 1..n to pick.
  "prompt": ["personal", "work", "safari", "firefox"],

  // Max seconds to wait when a rule calls resolve() to follow redirects.
  "resolveTimeoutSeconds": 5
}
"""#

/// Default `rules.js`, seeded into `~/.config/urlhandler/` on first run. Define a global
/// `route(url, ctx)` (sync or async). See the README for the full API and richer examples.
public let defaultRulesJS = #"""
// route(url, ctx) decides which browser opens a URL.
//
//   ctx = { opener: { bundleId, name } | null,   // the app that opened the link
//           browsers: [keys...],                  // browser keys available in config.json
//           default: key }                        // the configured default browser key
//
// Return one of:
//   { browser: "<key>" }            -> open in that browser
//   { browser: "<key>", url: "…" }  -> open a rewritten URL in that browser
//   { prompt: true }                -> show the chooser   (also: return nothing / null)
//   { prompt: true, url: "…" }      -> chooser, offering a rewritten URL
//
// Helpers (globals):
//   unwrap(url)  -> decode known link-tracking wrappers locally, no network (Slack, SafeLinks, …)
//   resolve(url) -> Promise<finalUrl>, follows redirects over the network (rejects on timeout/error)
//   console.log/warn/error, URL, URLSearchParams
//
// This is a starter example: it sends a few work tools to the "work" Chrome profile and a couple
// of personal sites to the "personal" profile, and shows the chooser for everything else. Edit the
// host lists, add an opener check (e.g. links from Slack -> work), or call unwrap()/resolve() to
// route by the real destination. See the README for those examples.

function route(url, ctx) {
  const href = url.toLowerCase();

  const workHosts = `
github.com
gitlab.com
atlassian.net
`.split(/\s+/).filter(w => w.length);

  const personalHosts = `
youtube.com
reddit.com
`.split(/\s+/).filter(w => w.length);

  if (workHosts.some(h => href.includes(h))) return { browser: "work" };
  if (personalHosts.some(h => href.includes(h))) return { browser: "personal" };
  return { prompt: true };
}
"""#
