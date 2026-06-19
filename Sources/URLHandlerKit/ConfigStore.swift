import CoreServices
import Foundation

/// Owns the current `Config` and `JSEngine`, and keeps them fresh as the user edits
/// `~/.config/urlhandler/{config.json,rules.js}`.
///
/// Hot reload is automatic and safe:
///  - An FSEvents watch on the config directory triggers reloads on change (robust to editors'
///    atomic save = write-temp-then-rename). `current()` also re-checks mtimes as a safety net,
///    so a missed event can't serve stale files on the next route.
///  - A reload parses the new config and builds a fresh `JSContext` into temporaries, swapping
///    them in only if BOTH succeed. A broken edit keeps the last-good config/engine and records
///    `lastError`, so a typo never breaks routing.
@MainActor
public final class ConfigStore {
    public private(set) var config: Config
    public private(set) var engine: JSEngine
    public private(set) var lastError: String?
    public private(set) var lastReload: Date

    public let directory: URL
    private let configURL: URL
    private let rulesURL: URL
    private let logger: JSEngine.Logger
    private let resolver: JSEngine.AsyncResolver
    private let resolverBox: MutableResolver?

    private var configMtime: Date?
    private var rulesMtime: Date?
    private var watcher: DirectoryWatcher?

    public nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/urlhandler", isDirectory: true)
    }

    /// - Parameters:
    ///   - injectedResolver: replaces the built-in network redirect-follower (for tests).
    ///   - watch: install the FSEvents watcher (disable in tests that reload manually).
    public init(
        directory: URL = ConfigStore.defaultDirectory,
        injectedResolver: JSEngine.AsyncResolver? = nil,
        watch: Bool = true,
        logger: @escaping JSEngine.Logger = { _, _ in }
    ) throws {
        self.directory = directory
        self.configURL = directory.appendingPathComponent("config.json")
        self.rulesURL = directory.appendingPathComponent("rules.js")
        self.logger = logger

        if let injectedResolver {
            self.resolver = injectedResolver
            self.resolverBox = nil
        } else {
            let box = MutableResolver(timeout: 5)
            self.resolverBox = box
            self.resolver = { try await box.finalURL(for: $0) }
        }

        try Self.seedDefaultsIfMissing(directory: directory, logger: logger)

        // Initial load; fall back to built-in defaults so the agent always has a working engine.
        do {
            let loaded = try Config.load(from: configURL)
            let rules = try String(contentsOf: rulesURL, encoding: .utf8)
            self.engine = try JSEngine(rulesSource: rules, resolver: resolver, logger: logger)
            self.config = loaded
            self.lastError = nil
        } catch {
            self.config = try Config.parse(Data(defaultConfigJSON.utf8))
            self.engine = try JSEngine(rulesSource: defaultRulesJS, resolver: resolver, logger: logger)
            self.lastError = "Using built-in defaults: \(error)"
            logger("error", self.lastError!)
        }

        self.resolverBox?.timeout = config.resolveTimeout
        self.configMtime = Self.modificationDate(configURL)
        self.rulesMtime = Self.modificationDate(rulesURL)
        self.lastReload = Date()
        config.warnings().forEach { logger("warn", $0) }

        if watch {
            self.watcher = DirectoryWatcher(path: directory.path) { [weak self] in
                self?.reloadIfChanged()
            }
        }
    }

    /// Current engine + config, reloading first if either file changed on disk.
    public func current() -> (config: Config, engine: JSEngine) {
        reloadIfChanged()
        return (config, engine)
    }

    public func reloadIfChanged() {
        if Self.modificationDate(configURL) != configMtime || Self.modificationDate(rulesURL) != rulesMtime {
            reload()
        }
    }

    public func forceReload() {
        reload()
    }

    private func reload() {
        let newConfigMtime = Self.modificationDate(configURL)
        let newRulesMtime = Self.modificationDate(rulesURL)
        do {
            let newConfig = try Config.load(from: configURL)
            let rules = try String(contentsOf: rulesURL, encoding: .utf8)
            let newEngine = try JSEngine(rulesSource: rules, resolver: resolver, logger: logger)
            // Both parsed/compiled: atomic swap.
            self.config = newConfig
            self.engine = newEngine
            self.resolverBox?.timeout = newConfig.resolveTimeout
            self.lastError = nil
            self.lastReload = Date()
            logger("info", "Reloaded config + rules")
            newConfig.warnings().forEach { logger("warn", $0) }
        } catch {
            self.lastError = String(describing: error)
            logger("error", "Reload failed; keeping last-good config/rules. \(error)")
        }
        // Record mtimes either way so we only retry once a file changes again.
        self.configMtime = newConfigMtime
        self.rulesMtime = newRulesMtime
    }

    // MARK: - Defaults

    public static func seedDefaultsIfMissing(directory: URL, logger: JSEngine.Logger = { _, _ in }) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let rulesURL = directory.appendingPathComponent("rules.js")
        if !fm.fileExists(atPath: configURL.path) {
            try defaultConfigJSON.write(to: configURL, atomically: true, encoding: .utf8)
            logger("info", "Seeded default config.json at \(configURL.path)")
        }
        if !fm.fileExists(atPath: rulesURL.path) {
            try defaultRulesJS.write(to: rulesURL, atomically: true, encoding: .utf8)
            logger("info", "Seeded default rules.js at \(rulesURL.path)")
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

/// Network resolver whose timeout can be updated as config reloads.
final class MutableResolver: @unchecked Sendable {
    var timeout: Double
    init(timeout: Double) { self.timeout = timeout }
    func finalURL(for url: String) async throws -> String {
        try await Resolver(timeout: timeout).finalURL(for: url)
    }
}

/// Watches a directory subtree via FSEvents, invoking `onChange` on the main queue.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?

    init?(path: String, onChange: @escaping () -> Void) {
        let box = OnChangeBox(onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<OnChangeBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<OnChangeBox>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
        ) else {
            if let info = context.info { Unmanaged<OnChangeBox>.fromOpaque(info).release() }
            return nil
        }
        self.stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

private final class OnChangeBox {
    let onChange: () -> Void
    init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
}
