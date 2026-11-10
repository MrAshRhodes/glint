import Combine
import Foundation
import GlintCapture
import GlintCore

/// Why a shortcut can't be used.
struct HotkeyProblem: Equatable {
    enum Reason: Equatable {
        /// Another Glint action already has the combination.
        case usedByGlint(HotkeyAction)
        /// macOS reports it as claimed by another app or by the system.
        case taken
        /// macOS refused it for another reason; the status, when it gave one.
        case failed(OSStatus?)
    }

    let combo: KeyCombo
    let reason: Reason

    var message: String {
        switch reason {
        case .usedByGlint(let other): return "\(combo.displayString) is already used by \(other.displayName)."
        case .taken: return "\(combo.displayString) is already used by another app or macOS."
        case .failed(let status?): return "macOS couldn't register \(combo.displayString) (error \(status))."
        case .failed(nil): return "macOS couldn't register \(combo.displayString)."
        }
    }

    /// For a change that was turned down: the shortcut keeps what it had.
    var rejectedMessage: String { message + " Your shortcut was not changed." }
    /// For a saved shortcut that isn't active.
    var inactiveMessage: String { message + " This shortcut isn't active; choose another." }
}

/// Keeps the system's global hotkeys in step with the saved shortcuts, and says so when one can't be used.
///
/// A combination that is already active is never registered again, so a preference change that has nothing to do
/// with shortcuts doesn't touch the system. A shortcut the user changes keeps working until its replacement is
/// registered, and is saved only then.
@MainActor
final class HotkeyController: ObservableObject {
    /// Saved shortcuts that aren't active, with the reason.
    @Published private(set) var problems: [HotkeyAction: HotkeyProblem] = [:]
    /// Told once about each problem found while syncing, because nobody is looking at the shortcut when it happens.
    var report: ([(action: HotkeyAction, problem: HotkeyProblem)]) -> Void = { _ in }

    private let prefs: AppPreferences
    private let center: HotkeyCenter
    private let perform: (HotkeyAction) -> Void
    private var reported: [HotkeyAction: KeyCombo] = [:]
    /// Set once a shortcut moved, which may have freed a combination another one was refused.
    private var releasedSinceSync = false

    init(prefs: AppPreferences, center: HotkeyCenter? = nil, perform: @escaping (HotkeyAction) -> Void) {
        self.prefs = prefs
        self.center = center ?? .shared
        self.perform = perform
    }

    /// Makes the active shortcuts match the saved ones, changing only what differs.
    ///
    /// A combination macOS refused is not asked for again until another shortcut has been released.
    func sync() {
        let saved = prefs.hotkeys
        func wanted(_ action: HotkeyAction) -> KeyCombo { saved[action] ?? action.defaultCombo }

        var released = releasedSinceSync
        releasedSinceSync = false
        // Letting go of what no longer matches first lets shortcuts that swap or chain claim each other's combinations.
        for action in HotkeyAction.allCases {
            guard let active = center.registeredCombo(for: action.rawValue),
                  active != RecordedKeyCombo(wanted(action)) else { continue }
            center.unregister(id: action.rawValue)
            released = true
        }

        var unmet: [HotkeyAction: HotkeyProblem] = [:]
        for action in HotkeyAction.allCases where center.registeredCombo(for: action.rawValue) == nil {
            let combo = wanted(action)
            if !released, let known = problems[action], known.combo == combo {
                unmet[action] = known
            } else if let problem = claim(combo, for: action) {
                unmet[action] = problem
            }
        }
        settle(unmet)
    }

    /// Moves `action` to `combo` and saves it. A combination another action has, or one macOS refuses, changes
    /// nothing: the shortcut that worked keeps working, and the reason comes back.
    func change(_ action: HotkeyAction, to combo: KeyCombo) -> HotkeyProblem? {
        if let other = prefs.hotkeyConflict(for: combo, assigning: action) {
            return HotkeyProblem(combo: combo, reason: .usedByGlint(other))
        }
        if let problem = claim(combo, for: action) { return problem }
        prefs.setHotkey(combo, for: action)
        releasedSinceSync = true
        reported[action] = nil
        if problems[action] != nil { problems[action] = nil }
        return nil
    }

    /// Registers `combo` for `action`; the problem when it can't be.
    private func claim(_ combo: KeyCombo, for action: HotkeyAction) -> HotkeyProblem? {
        let recorded = RecordedKeyCombo(combo)
        if let holder = HotkeyAction.allCases.first(where: { $0 != action && center.registeredCombo(for: $0.rawValue) == recorded }) {
            return HotkeyProblem(combo: combo, reason: .usedByGlint(holder))
        }
        do {
            try center.register(id: action.rawValue, combo: recorded) { [perform] in perform(action) }
            return nil
        } catch {
            let status = (error as? HotkeyError)?.status
            let taken = (error as? HotkeyError)?.isAlreadyRegistered == true
            return HotkeyProblem(combo: combo, reason: taken ? .taken : .failed(status))
        }
    }

    private func settle(_ unmet: [HotkeyAction: HotkeyProblem]) {
        if unmet != problems { problems = unmet }
        var fresh: [(action: HotkeyAction, problem: HotkeyProblem)] = []
        for action in HotkeyAction.allCases {
            guard let problem = unmet[action] else { reported[action] = nil; continue }
            guard reported[action] != problem.combo else { continue }
            reported[action] = problem.combo
            fresh.append((action, problem))
        }
        if !fresh.isEmpty { report(fresh) }
    }

    /// The notification that tells the user about shortcuts that can't be used.
    static func notification(for reports: [(action: HotkeyAction, problem: HotkeyProblem)]) -> (title: String, body: String) {
        if reports.count == 1, let only = reports.first {
            return ("Shortcut unavailable",
                    "\(only.problem.message) “\(only.action.displayName)” won't work until you choose another in Settings.")
        }
        let names = reports.map(\.action.displayName).joined(separator: ", ")
        return ("\(reports.count) shortcuts unavailable", "These won't work until you choose others in Settings: \(names).")
    }
}
