import Foundation

/// The modifier keys KongFetch distinguishes when watching for a double tap.
public struct ModifierSet: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control  = ModifierSet(rawValue: 1 << 0)
    public static let option   = ModifierSet(rawValue: 1 << 1)
    public static let command  = ModifierSet(rawValue: 1 << 2)
    public static let shift    = ModifierSet(rawValue: 1 << 3)
    public static let function = ModifierSet(rawValue: 1 << 4)
}

/// Which modifier, if any, wakes KongFetch when tapped twice.
public enum TapModifier: String, CaseIterable, Codable, Identifiable {
    case off, control, option, command, shift

    public var id: String { rawValue }

    public var modifierSet: ModifierSet {
        switch self {
        case .off: return []
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }

    public var title: String {
        switch self {
        case .off: return "关闭"
        case .control: return "Control ⌃"
        case .option: return "Option ⌥"
        case .command: return "Command ⌘"
        case .shift: return "Shift ⇧"
        }
    }
}

/// Recognises "press and release the trigger, twice, with nothing else in between".
public struct DoubleTapDetector: Equatable {
    public enum Input: Equatable {
        case triggerDown
        case triggerUp
        /// Any other key or modifier. Cancels the gesture in progress.
        case interrupt
    }

    /// Longest a single press may be held and still count as a tap.
    public var maximumHold: TimeInterval
    /// Longest pause between the first release and the second press.
    public var maximumGap: TimeInterval

    private var pressedAt: TimeInterval?
    private var lastTapEndedAt: TimeInterval?

    public init(maximumHold: TimeInterval = 0.45, maximumGap: TimeInterval = 0.5) {
        self.maximumHold = maximumHold
        self.maximumGap = maximumGap
    }

    public mutating func reset() {
        pressedAt = nil
        lastTapEndedAt = nil
    }

    /// Feeds one input. Returns `true` exactly when it completes a double tap.
    public mutating func handle(_ input: Input, at time: TimeInterval) -> Bool {
        switch input {
        case .interrupt:
            reset()
            return false
        case .triggerDown:
            if pressedAt == nil { pressedAt = time }
            return false
        case .triggerUp:
            guard let down = pressedAt else { return false }
            pressedAt = nil
            guard time - down <= maximumHold else {
                lastTapEndedAt = nil
                return false
            }
            if let previous = lastTapEndedAt, down >= previous, down - previous <= maximumGap {
                lastTapEndedAt = nil
                return true
            }
            lastTapEndedAt = time
            return false
        }
    }
}

/// Turns successive modifier-flag snapshots into detector inputs.
public enum ModifierTransition {
    /// - Parameters:
    ///   - previouslyDown: whether the trigger was down in the previous snapshot.
    ///   - current: the modifiers held now.
    ///   - trigger: the trigger modifier.
    /// - Returns: the input to feed (if any) and whether the trigger is down now.
    public static func input(previouslyDown: Bool, current: ModifierSet, trigger: ModifierSet) -> (input: DoubleTapDetector.Input?, isDown: Bool) {
        let isDown = !trigger.isEmpty && current.isSuperset(of: trigger)
        if !current.subtracting(trigger).isEmpty {
            return (.interrupt, isDown)
        }
        if isDown && !previouslyDown { return (.triggerDown, true) }
        if !isDown && previouslyDown { return (.triggerUp, false) }
        return (nil, isDown)
    }
}
