import Foundation
import URLHandlerKit

@MainActor
func runLauncherTests(_ h: Harness) async {
    h.suite("Launcher — open argument construction")

    let url = "https://example.com/x"

    // Chrome with a profile: -n is mandatory, profile via --profile-directory.
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "Google Chrome", profile: "Profile 1"), url: url),
        ["-n", "-a", "Google Chrome", "--args", "--profile-directory=Profile 1", url],
        "chrome + profile")

    // No profile: plain open -a App <url>, no -n, no --args.
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "Safari"), url: url),
        ["-a", "Safari", url],
        "safari, no profile")

    // Bundle id -> -b.
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "com.google.Chrome", profile: "Default"), url: url),
        ["-n", "-b", "com.google.Chrome", "--args", "--profile-directory=Default", url],
        "bundle id + profile")

    // Absolute path -> -a <path>.
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "/Applications/Google Chrome.app", profile: "Default"), url: url),
        ["-n", "-a", "/Applications/Google Chrome.app", "--args", "--profile-directory=Default", url],
        "path + profile")

    // Firefox profile -> -P <name>, with -n.
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "Firefox", profile: "work"), url: url),
        ["-n", "-a", "Firefox", "--args", "-P", "work", url],
        "firefox + profile")

    // Non-profile browser ignores a stray profile (no --profile-directory, no -n).
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "Safari", profile: "X"), url: url),
        ["-a", "Safari", url],
        "non-profile browser ignores profile")

    // Extra args are appended after the profile flag.
    h.expectEqual(
        Launcher.openArguments(for: BrowserConfig(app: "Google Chrome", profile: "Default", args: ["--incognito"]), url: url),
        ["-n", "-a", "Google Chrome", "--args", "--profile-directory=Default", "--incognito", url],
        "extra args appended")

    h.suite("ChromeProfiles — Local State parsing")

    let fixture = """
        {
          "profile": {
            "info_cache": {
              "Default":   { "name": "Personal", "gaia_id": "1" },
              "Profile 1": { "name": "Work" },
              "Profile 2": { "name": "Testing" }
            }
          }
        }
        """
    do {
        let profiles = try ChromeProfiles.parse(Data(fixture.utf8))
        h.expectEqual(profiles.count, 3, "parses 3 profiles")
        h.expectEqual(profiles.first?.directory, "Default", "sorted, Default first")
        h.expectEqual(profiles.first(where: { $0.directory == "Profile 1" })?.name, "Work", "Profile 1 -> Work")
    } catch {
        h.fail("ChromeProfiles.parse", "threw \(error)")
    }

    // Missing/empty Local State -> empty list, no throw.
    do {
        let empty = try ChromeProfiles.parse(Data("{}".utf8))
        h.expectEqual(empty.count, 0, "empty Local State -> no profiles")
    } catch {
        h.fail("ChromeProfiles empty", "threw \(error)")
    }
}
