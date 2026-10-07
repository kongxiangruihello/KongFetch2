import XCTest
@testable import KongFetchCore

final class DoubleTapTests: XCTestCase {
    func testQuickDoubleTapFires() {
        var d = DoubleTapDetector()
        XCTAssertFalse(d.handle(.triggerDown, at: 0.00))
        XCTAssertFalse(d.handle(.triggerUp, at: 0.08))
        XCTAssertFalse(d.handle(.triggerDown, at: 0.20))
        XCTAssertTrue(d.handle(.triggerUp, at: 0.28))
    }

    func testThirdTapStartsOver() {
        var d = DoubleTapDetector()
        _ = d.handle(.triggerDown, at: 0); _ = d.handle(.triggerUp, at: 0.05)
        _ = d.handle(.triggerDown, at: 0.15)
        XCTAssertTrue(d.handle(.triggerUp, at: 0.2))
        _ = d.handle(.triggerDown, at: 0.3)
        XCTAssertFalse(d.handle(.triggerUp, at: 0.35))
    }

    func testLongHoldDoesNotCount() {
        var d = DoubleTapDetector()
        _ = d.handle(.triggerDown, at: 0); _ = d.handle(.triggerUp, at: 0.05)
        _ = d.handle(.triggerDown, at: 0.15)
        XCTAssertFalse(d.handle(.triggerUp, at: 0.9))
    }

    func testSlowSecondTapDoesNotCount() {
        var d = DoubleTapDetector()
        _ = d.handle(.triggerDown, at: 0); _ = d.handle(.triggerUp, at: 0.05)
        _ = d.handle(.triggerDown, at: 0.8)
        XCTAssertFalse(d.handle(.triggerUp, at: 0.85))
    }

    func testOtherKeyInBetweenCancels() {
        var d = DoubleTapDetector()
        _ = d.handle(.triggerDown, at: 0); _ = d.handle(.triggerUp, at: 0.05)
        _ = d.handle(.interrupt, at: 0.1)
        _ = d.handle(.triggerDown, at: 0.15)
        XCTAssertFalse(d.handle(.triggerUp, at: 0.2))
    }

    func testControlShortcutDoesNotCount() {
        // Control+C, Control+C must not wake the app.
        var d = DoubleTapDetector()
        var down = false
        func feed(_ mods: ModifierSet, key: Bool = false, _ t: TimeInterval) -> Bool {
            if key { return d.handle(.interrupt, at: t) }
            let r = ModifierTransition.input(previouslyDown: down, current: mods, trigger: .control)
            down = r.isDown
            return r.input.map { d.handle($0, at: t) } ?? false
        }
        XCTAssertFalse(feed([.control], 0))
        XCTAssertFalse(feed([.control], key: true, 0.05))
        XCTAssertFalse(feed([], 0.1))
        XCTAssertFalse(feed([.control], 0.2))
        XCTAssertFalse(feed([.control], key: true, 0.25))
        XCTAssertFalse(feed([], 0.3))
    }

    func testTransitionWithOtherModifierInterrupts() {
        let r = ModifierTransition.input(previouslyDown: true, current: [.control, .shift], trigger: .control)
        XCTAssertEqual(r.input, .interrupt)
        XCTAssertTrue(r.isDown)
        let up = ModifierTransition.input(previouslyDown: true, current: [], trigger: .control)
        XCTAssertEqual(up.input, .triggerUp)
        let off = ModifierTransition.input(previouslyDown: false, current: [.control], trigger: [])
        XCTAssertEqual(off.input, .interrupt)
    }

    func testEveryTriggerModifierWorks() {
        for modifier in TapModifier.allCases where modifier != .off {
            var d = DoubleTapDetector()
            var down = false
            var fired = false
            for (mods, t) in [(modifier.modifierSet, 0.0), (ModifierSet(), 0.05), (modifier.modifierSet, 0.15), (ModifierSet(), 0.2)] {
                let r = ModifierTransition.input(previouslyDown: down, current: mods, trigger: modifier.modifierSet)
                down = r.isDown
                if let input = r.input, d.handle(input, at: t) { fired = true }
            }
            XCTAssertTrue(fired, "\(modifier)")
        }
    }
}
