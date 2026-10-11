import Foundation

@MainActor
func runAll() async {
    let harness = Harness()
    await runJSEngineTests(harness)
    await runConfigTests(harness)
    await runResolverTests(harness)
    await runLauncherTests(harness)
    await runInteractionGraceTests(harness)
    await runChooserTests(harness)
    harness.finish()
}

await runAll()
