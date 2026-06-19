import Foundation
import URLHandlerKit

@MainActor
func runChooserTests(_ h: Harness) async {
    h.suite("Chooser — key handling")

    // Digit keys pick by 1-based index (regardless of current selection).
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "1", command: false, optionsCount: 5, selected: 3),
        .pick(0), "digit 1 picks first")
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "5", command: false, optionsCount: 5, selected: 0),
        .pick(4), "digit 5 picks fifth")
    // Out-of-range digit ignored.
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "6", command: false, optionsCount: 5, selected: 0),
        .ignore, "digit beyond count ignored")

    // ⌘C copies; ⌘ + other key ignored.
    h.expectEqual(
        chooserKeyAction(keyCode: 8, characters: "c", command: true, optionsCount: 3, selected: 0),
        .copy, "cmd-c copies")
    h.expectEqual(
        chooserKeyAction(keyCode: 0, characters: "x", command: true, optionsCount: 3, selected: 0),
        .ignore, "cmd-other ignored")

    // Esc cancels.
    h.expectEqual(
        chooserKeyAction(keyCode: 53, characters: nil, command: false, optionsCount: 3, selected: 1),
        .cancel, "esc cancels")

    // Return/enter pick the current selection.
    h.expectEqual(
        chooserKeyAction(keyCode: 36, characters: nil, command: false, optionsCount: 3, selected: 2),
        .pick(2), "return picks selected")

    // Arrows move selection within bounds.
    h.expectEqual(
        chooserKeyAction(keyCode: 125, characters: nil, command: false, optionsCount: 3, selected: 0),
        .select(1), "down moves selection")
    h.expectEqual(
        chooserKeyAction(keyCode: 125, characters: nil, command: false, optionsCount: 3, selected: 2),
        .select(2), "down clamps at last")
    h.expectEqual(
        chooserKeyAction(keyCode: 126, characters: nil, command: false, optionsCount: 3, selected: 0),
        .select(0), "up clamps at first")
}
