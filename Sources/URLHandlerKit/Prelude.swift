import Foundation

/// JavaScript prelude evaluated into every fresh `JSContext` before the user's `rules.js`.
///
/// A bare `JSContext` provides full ECMAScript (Promise, async/await, JSON, RegExp,
/// decodeURIComponent, ...) but none of the Web/Node globals. This prelude supplies the
/// pieces routing rules realistically need:
///   - `console.{log,info,warn,error,debug}` -> native `__log(level, message)`
///   - `URL` / `URLSearchParams` -> backed by Foundation `URLComponents` via native `__parseURL`
///   - `unwrap(url)` -> decode known link-tracking wrappers locally (no network)
///
/// The native functions `__log`, `__parseURL`, and `resolve` are installed by `JSEngine`
/// before this script runs.
public let preludeJS = #"""
(function (g) {
  "use strict";

  // ---- console -------------------------------------------------------------
  function mkLog(level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) {
        var a = arguments[i];
        try {
          parts.push(typeof a === "object" && a !== null ? JSON.stringify(a) : String(a));
        } catch (e) {
          parts.push(String(a));
        }
      }
      __log(level, parts.join(" "));
    };
  }
  g.console = {
    log: mkLog("log"),
    info: mkLog("info"),
    warn: mkLog("warn"),
    error: mkLog("error"),
    debug: mkLog("debug"),
  };

  // ---- URLSearchParams (read-focused subset) -------------------------------
  function URLSearchParams(pairs) {
    this._p = pairs ? pairs.slice() : [];
  }
  URLSearchParams.prototype.get = function (k) {
    for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) return this._p[i][1];
    return null;
  };
  URLSearchParams.prototype.getAll = function (k) {
    var r = [];
    for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) r.push(this._p[i][1]);
    return r;
  };
  URLSearchParams.prototype.has = function (k) {
    return this.get(k) !== null;
  };
  URLSearchParams.prototype.forEach = function (fn, thisArg) {
    for (var i = 0; i < this._p.length; i++) fn.call(thisArg, this._p[i][1], this._p[i][0], this);
  };
  URLSearchParams.prototype.toString = function () {
    return this._p
      .map(function (e) {
        return encodeURIComponent(e[0]) + "=" + encodeURIComponent(e[1]);
      })
      .join("&");
  };
  g.URLSearchParams = URLSearchParams;

  // ---- URL (native-backed via __parseURL) ----------------------------------
  function URL(input, base) {
    var c = __parseURL(String(input), base == null ? null : String(base));
    if (!c) throw new TypeError("Invalid URL: " + input);
    this.href = c.href;
    this.protocol = c.protocol;
    this.host = c.host;
    this.hostname = c.hostname;
    this.port = c.port;
    this.pathname = c.pathname;
    this.search = c.search;
    this.hash = c.hash;
    this.origin = c.origin;
    this.searchParams = new URLSearchParams(c.queryItems || []);
  }
  URL.prototype.toString = function () {
    return this.href;
  };
  g.URL = URL;

  // ---- unwrap(url): decode known link-tracking wrappers locally ------------
  // Returns the embedded destination for known trackers, else the input unchanged.
  function isHttp(s) {
    return typeof s === "string" && /^https?:\/\//i.test(s);
  }

  function unwrapOnce(url) {
    var u;
    try {
      u = new URL(url);
    } catch (e) {
      return url;
    }
    var host = u.hostname.toLowerCase();

    // Proofpoint URLDefense v2: ?u=, with '-'->'%' and '_'->'/', then percent-decode.
    if (/(^|\.)urldefense\.(proofpoint\.)?com$/.test(host) || host === "urldefense.us") {
      if (u.pathname.indexOf("/v2/") === 0) {
        var raw = u.searchParams.get("u");
        if (raw) {
          try {
            var decoded = decodeURIComponent(raw.replace(/-/g, "%").replace(/_/g, "/"));
            if (isHttp(decoded)) return decoded;
          } catch (e) {}
        }
      }
    }

    // Query-parameter wrappers: [hostMatch, [paramNames...]]
    var WRAPPERS = [
      [host === "slack-redir.net", ["url"]],
      [/(^|\.)safelinks\.protection\.outlook\.com$/.test(host), ["url"]],
      [host === "statics.teams.cdn.office.net" || host === "teams.public.onecdn.static.microsoft", ["url"]],
      [(host === "www.google.com" || host === "google.com") && u.pathname === "/url", ["url", "q"]],
      [host === "l.facebook.com" || host === "lm.facebook.com", ["u"]],
      [host === "click.redditmedia.com", ["u"]],
    ];
    for (var i = 0; i < WRAPPERS.length; i++) {
      if (!WRAPPERS[i][0]) continue;
      var keys = WRAPPERS[i][1];
      for (var j = 0; j < keys.length; j++) {
        var v = u.searchParams.get(keys[j]);
        if (isHttp(v)) return v;
      }
    }
    return url;
  }

  g.unwrap = function (url) {
    var cur = url;
    var seen = Object.create(null);
    for (var i = 0; i < 5; i++) {
      // unwrap nested wrappers, with a small depth cap and loop guard
      if (seen[cur]) break;
      seen[cur] = true;
      var next = unwrapOnce(cur);
      if (next === cur) break;
      cur = next;
    }
    return cur;
  };
})(this);
"""#
