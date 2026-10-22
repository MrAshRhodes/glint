import AppKit
import Combine
import GlintCore
import Testing
@testable import Glint

@Suite("Snapping preferences")
@MainActor
struct SnappingPreferencesTests {
    @Test func menuUsesPersistedPreferenceAndNotifiesAfterToggling() throws {
        let suite = "glint.snapping.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults)
        let menu = NSMenu()
        let delegate = AppDelegate(prefs: prefs, menu: menu)
        var observedStates: [Bool] = []
        let observer = NotificationCenter.default.publisher(for: .glintPreferencesChanged).sink { _ in
            observedStates.append(prefs.snapToEdges)
        }
        defer { observer.cancel() }

        delegate.menuNeedsUpdate(menu)
        let item = try #require(menu.item(withTitle: "Snap to Edges"))
        #expect(item.state == .off)
        #expect(item.target === delegate)
        #expect(menu.index(of: item) == menu.indexOfItem(withTitle: "Capture with Timer") + 1)
        let action = try #require(item.action)

        _ = delegate.perform(action)
        #expect(AppPreferences(defaults: defaults).snapToEdges)
        #expect(observedStates == [true])
        delegate.menuNeedsUpdate(menu)
        #expect(menu.item(withTitle: "Snap to Edges")?.state == .on)

        _ = delegate.perform(action)
        #expect(!prefs.snapToEdges)
        #expect(observedStates == [true, false])
        delegate.menuNeedsUpdate(menu)
        #expect(menu.item(withTitle: "Snap to Edges")?.state == .off)

        defaults.set(true, forKey: AppPreferences.Key.snapToEdges)
        delegate.menuNeedsUpdate(menu)
        #expect(menu.item(withTitle: "Snap to Edges")?.state == .on)
        prefs.resetToDefaults()
        delegate.menuNeedsUpdate(menu)
        #expect(menu.item(withTitle: "Snap to Edges")?.state == .off)
    }
}
