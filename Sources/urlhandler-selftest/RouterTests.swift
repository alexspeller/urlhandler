import Foundation
import URLHandlerKit

@MainActor
func runRouterTests(_ h: Harness) async {
    h.suite("Router — local files opened as the default browser")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("urlhandler-selftest-\(ProcessInfo.processInfo.globallyUniqueString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Rules can send every file in a folder to one browser by matching the file:// URL's path
    // prefix, ahead of word rules that would otherwise claim it (here "github" in the file name).
    let config = """
        {
          "browsers": {
            "personal": { "app": "Google Chrome", "profile": "Default" },
            "work":     { "app": "Google Chrome", "profile": "Profile 1" }
          },
          "default": "personal",
          "prompt": ["personal", "work"]
        }
        """
    let rules = """
        function route(url, ctx) {
          const href = url.toLowerCase();
          if (href.startsWith("file:///users/someone/library/caches/")) return { browser: "personal" };
          if (href.includes("github")) return { browser: "work" };
          return { prompt: true };
        }
        """

    var opened: [(browser: BrowserConfig, url: String)] = []
    var chooserURLs: [String] = []
    let router: Router
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try rules.write(to: dir.appendingPathComponent("rules.js"), atomically: true, encoding: .utf8)
        let store = try ConfigStore(directory: dir, injectedResolver: { $0 }, watch: false)
        h.expect(store.lastError == nil, "test rules load", store.lastError ?? "")
        router = Router(
            store: store,
            presentChooser: { url, _, _ in chooserURLs.append(url) },
            openBrowser: { browser, url in opened.append((browser, url)) }
        )
    } catch {
        h.fail("router setup", "threw \(error)")
        return
    }

    // A file under the matched folder opens straight in that browser, with no chooser. The rule
    // sees file:// plus the absolute path, percent-encoded (the space in the name is %20).
    await router.handle(filePath: "/Users/someone/Library/Caches/com.example.app/attachments/1f2e/github review.html")
    h.expectEqual(opened.count, 1, "file under the folder: opened once")
    h.expectEqual(opened.first?.browser, BrowserConfig(app: "Google Chrome", profile: "Default"),
                  "file under the folder: opened in the rule's browser")
    h.expectEqual(opened.first?.url,
                  "file:///Users/someone/Library/Caches/com.example.app/attachments/1f2e/github%20review.html",
                  "file under the folder: opened as its file:// URL")
    h.expectEqual(chooserURLs, [], "file under the folder: no chooser")

    // A file elsewhere matches no rule and still gets the chooser, offering its file:// URL.
    opened = []
    await router.handle(filePath: "/Users/someone/Downloads/page.html")
    h.expectEqual(opened.count, 0, "file elsewhere: nothing opened directly")
    h.expectEqual(chooserURLs, ["file:///Users/someone/Downloads/page.html"], "file elsewhere: chooser shown")
}
