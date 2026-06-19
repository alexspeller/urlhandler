import Foundation
import URLHandlerKit

@MainActor
func runConfigTests(_ h: Harness) async {
    h.suite("Config — parsing & comment stripping")

    // Built-in defaults must parse and build.
    do {
        let config = try Config.parse(Data(defaultConfigJSON.utf8))
        h.expect(config.browsers["work"]?.profile == "Profile 1", "default config parses (work=Profile 1)")
        h.expect(config.defaultBrowser == "personal", "default browser = personal")
        h.expect(config.prompt.first == "personal", "prompt order preserved")
        h.expect(config.resolveTimeout == 5, "resolveTimeout default from config")
    } catch {
        h.fail("default config parses", "threw \(error)")
    }

    // Comments stripped, but `//` inside string values preserved.
    do {
        let json = """
            {
              // line comment
              "browsers": { "x": { "app": "Safari" } }, /* block */
              "default": "x",
              "prompt": ["x"]
            }
            """
        let config = try Config.parse(Data(json.utf8))
        h.expect(config.browsers["x"]?.app == "Safari", "comments stripped, parses")
    } catch {
        h.fail("comment stripping", "threw \(error)")
    }
    do {
        // A value containing `//` (URL-like) must survive comment stripping.
        let json = #"{ "browsers": { "x": { "app": "https://example.com/app" } } }"#
        let config = try Config.parse(Data(json.utf8))
        h.expectEqual(config.browsers["x"]?.app, "https://example.com/app", "// inside string preserved")
    } catch {
        h.fail("// inside string", "threw \(error)")
    }

    // Missing-key warnings.
    do {
        let config = Config(
            browsers: ["a": BrowserConfig(app: "Safari")],
            defaultBrowser: "missing",
            prompt: ["a", "ghost"]
        )
        let warnings = config.warnings()
        h.expect(warnings.contains { $0.contains("missing") }, "warns about missing default")
        h.expect(warnings.contains { $0.contains("ghost") }, "warns about missing prompt key")
    }

    h.suite("ConfigStore — seeding & safe hot reload")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("urlhandler-selftest-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    do {
        // First run seeds defaults and builds a working engine.
        let store = try ConfigStore(directory: dir, injectedResolver: { $0 }, watch: false)
        h.expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path),
                 "seeds config.json")
        h.expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rules.js").path),
                 "seeds rules.js")
        h.expect(store.lastError == nil, "no error after seeding", store.lastError ?? "")

        // Default rules route by substring: "github.com" -> work, "youtube" -> personal, else prompt.
        let (config, engine) = store.current()
        let work = try await engine.route(
            url: "https://github.com/a/b", ctx: CLI.makeContext(config: config, openerBundleID: nil, openerName: nil))
        h.expectEqual(work, .browser(key: "work", url: nil), "seeded rules route github -> work")
        let yt = try await engine.route(
            url: "https://youtube.com/watch", ctx: CLI.makeContext(config: config, openerBundleID: nil, openerName: nil))
        h.expectEqual(yt, .browser(key: "personal", url: nil), "seeded rules route youtube -> personal")
        // Local HTML file opens arrive as file:// URLs and route through the same rules.
        let fileURL = try await engine.route(
            url: "file:///Users/x/Downloads/page.html", ctx: CLI.makeContext(config: config, openerBundleID: nil, openerName: nil))
        h.expectEqual(fileURL, .prompt(url: nil), "unmatched file:// URL -> chooser")

        // Valid edit applies on reload.
        let rulesURL = dir.appendingPathComponent("rules.js")
        try #"function route(u,c){ return { browser: "safari" }; }"#.write(to: rulesURL, atomically: true, encoding: .utf8)
        try bump(rulesURL)
        store.reloadIfChanged()
        h.expect(store.lastError == nil, "valid edit reloads cleanly", store.lastError ?? "")
        let after = try await store.current().engine.route(url: "https://anything.example", ctx: ["opener": NSNull()])
        h.expectEqual(after, .browser(key: "safari", url: nil), "valid edit takes effect")

        // Broken edit keeps the last-good engine.
        try "function route( {  // broken".write(to: rulesURL, atomically: true, encoding: .utf8)
        try bump(rulesURL)
        store.reloadIfChanged()
        h.expect(store.lastError != nil, "broken edit records an error")
        let stillWorks = try await store.current().engine.route(url: "https://anything.example", ctx: ["opener": NSNull()])
        h.expectEqual(stillWorks, .browser(key: "safari", url: nil), "broken edit keeps last-good rules")

        // Fixing it recovers.
        try #"function route(u,c){ return { browser: "firefox" }; }"#.write(to: rulesURL, atomically: true, encoding: .utf8)
        try bump(rulesURL)
        store.reloadIfChanged()
        h.expect(store.lastError == nil, "recovers after fix", store.lastError ?? "")
        let fixed = try await store.current().engine.route(url: "https://anything.example", ctx: ["opener": NSNull()])
        h.expectEqual(fixed, .browser(key: "firefox", url: nil), "fixed edit takes effect")
    } catch {
        h.fail("ConfigStore safe reload", "threw \(error)")
    }
}

/// Forces a distinct modification date so `reloadIfChanged()` reliably detects the write.
private func bump(_ url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
}
