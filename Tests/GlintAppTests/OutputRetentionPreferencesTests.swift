import Combine
import Foundation
import GlintCore
import Testing
@testable import Glint

@Suite("Output retention preferences")
@MainActor
struct OutputRetentionPreferencesTests {
    @Test func offersForeverThenTheFinitePeriodsInOrder() {
        let periods = OutputRetentionSection.periods

        #expect(periods == [.forever, .oneDay, .sevenDays, .thirtyDays, .ninetyDays])
        #expect(periods.map(\.displayName) == ["Forever", "1 day", "7 days", "30 days", "90 days"])
        #expect(periods.map(\.days) == [nil, 1, 7, 30, 90])
        #expect(Set(periods.map(\.id)).count == periods.count)
        #expect(OutputRetentionSection.keepTitle == "Keep copied and dragged screenshots for reopening")
        #expect(OutputRetentionSection.periodTitle == "Keep screenshots in Output for")
    }

    @Test func bothSettingsStartOffAndForeverAndWriteNothing() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }

        #expect(!fixture.model.bind(\.keepCopiedImages).wrappedValue)
        #expect(fixture.model.bind(\.outputRetention).wrappedValue == .forever)
        #expect(fixture.defaults.object(forKey: AppPreferences.Key.keepCopiedImages) == nil)
        #expect(fixture.defaults.object(forKey: AppPreferences.Key.outputRetentionDays) == nil)
        #expect(OutputRetentionSection.isEnabled(fixture.prefs))
    }

    @Test func keepToggleBindingPersistsRefreshesTheTabAndNotifies() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let keep = fixture.model.bind(\.keepCopiedImages)
        var refreshes = 0
        var observed: [Bool] = []
        let refresh = fixture.model.objectWillChange.sink { refreshes += 1 }
        let observer = NotificationCenter.default.publisher(for: .glintPreferencesChanged).sink { _ in
            observed.append(fixture.persisted.keepCopiedImages)
        }
        defer { refresh.cancel(); observer.cancel() }

        keep.wrappedValue = true
        #expect(fixture.persisted.keepCopiedImages)
        #expect(refreshes == 1)
        #expect(observed.last == true)

        keep.wrappedValue = false
        #expect(!fixture.persisted.keepCopiedImages)
        #expect(refreshes == 2)
        #expect(observed.last == false)
        #expect(fixture.defaults.object(forKey: AppPreferences.Key.keepCopiedImages) as? Bool == false)
    }

    @Test func periodPickerBindingPersistsEveryChoiceAndNotifies() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let picker = fixture.model.bind(\.outputRetention)
        var refreshes = 0
        var notifications = 0
        let refresh = fixture.model.objectWillChange.sink { refreshes += 1 }
        let observer = NotificationCenter.default.publisher(for: .glintPreferencesChanged).sink { _ in
            notifications += 1
        }
        defer { refresh.cancel(); observer.cancel() }

        for (index, period) in OutputRetentionSection.periods.reversed().enumerated() {
            let notified = notifications
            picker.wrappedValue = period

            #expect(picker.wrappedValue == period)
            #expect(fixture.persisted.outputRetention == period)
            #expect(fixture.defaults.object(forKey: AppPreferences.Key.outputRetentionDays) as? Int == period.rawValue)
            #expect(refreshes == index + 1)
            #expect(notifications > notified)
        }
    }

    @Test func controlsAreDimmedWhileHistoryIsOffAndKeepTheirChoices() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.bind(\.keepCopiedImages).wrappedValue = true
        model.bind(\.outputRetention).wrappedValue = .thirtyDays
        #expect(OutputRetentionSection.isEnabled(fixture.prefs))
        #expect(OutputRetentionSection.keepCaption(fixture.prefs) == OutputRetentionSection.keepDetail)
        #expect(OutputRetentionSection.periodCaption(fixture.prefs) == OutputRetentionSection.periodDetail)

        model.bind(\.saveHistory).wrappedValue = false

        #expect(!OutputRetentionSection.isEnabled(fixture.prefs))
        #expect(OutputRetentionSection.keepCaption(fixture.prefs) == OutputRetentionSection.keepPausedDetail)
        #expect(OutputRetentionSection.periodCaption(fixture.prefs) == OutputRetentionSection.periodPausedDetail)
        #expect(model.bind(\.keepCopiedImages).wrappedValue)
        #expect(model.bind(\.outputRetention).wrappedValue == .thirtyDays)

        model.bind(\.saveHistory).wrappedValue = true

        #expect(OutputRetentionSection.isEnabled(fixture.prefs))
        #expect(OutputRetentionSection.keepCaption(fixture.prefs) == OutputRetentionSection.keepDetail)
        #expect(fixture.persisted.keepCopiedImages)
        #expect(fixture.persisted.outputRetention == .thirtyDays)
    }

    @Test func changingThemNeverTouchesHistoryRawOrStyledOutput() {
        let combinations = [(true, true, true), (true, false, false), (false, true, false), (false, false, true)]
        for (history, raw, styled) in combinations {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            fixture.prefs.saveHistory = history
            fixture.prefs.saveRaw = raw
            fixture.prefs.saveOutput = styled

            fixture.model.bind(\.keepCopiedImages).wrappedValue = true
            fixture.model.bind(\.outputRetention).wrappedValue = .sevenDays
            fixture.model.bind(\.keepCopiedImages).wrappedValue = false
            fixture.model.bind(\.outputRetention).wrappedValue = .forever

            #expect(fixture.persisted.saveHistory == history)
            #expect(fixture.persisted.saveRaw == raw)
            #expect(fixture.persisted.saveOutput == styled)
        }
    }

    @Test func resetAllPreferencesRestoresBothDefaults() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.bind(\.keepCopiedImages).wrappedValue = true
        model.bind(\.outputRetention).wrappedValue = .ninetyDays
        #expect(AppPreferences.Key.all.contains(AppPreferences.Key.keepCopiedImages))
        #expect(AppPreferences.Key.all.contains(AppPreferences.Key.outputRetentionDays))
        #expect(fixture.persisted.keepCopiedImages)
        #expect(fixture.persisted.outputRetention == .ninetyDays)

        fixture.prefs.resetToDefaults()

        #expect(!fixture.persisted.keepCopiedImages)
        #expect(fixture.persisted.outputRetention == .forever)
        #expect(fixture.defaults.object(forKey: AppPreferences.Key.keepCopiedImages) == nil)
        #expect(fixture.defaults.object(forKey: AppPreferences.Key.outputRetentionDays) == nil)
        #expect(!model.bind(\.keepCopiedImages).wrappedValue)
        #expect(model.bind(\.outputRetention).wrappedValue == .forever)
    }

    @Test func anUnknownStoredPeriodStillShowsAListedChoice() {
        for stored in [-7, 2, 14, 365] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            fixture.defaults.set(stored, forKey: AppPreferences.Key.outputRetentionDays)

            let shown = fixture.model.bind(\.outputRetention).wrappedValue

            #expect(shown == .forever)
            #expect(OutputRetentionSection.periods.contains(shown))
        }
    }

    @Test func captionsExplainHowTheSettingsFitTogether() {
        let keep = OutputRetentionSection.keepDetail
        for phrase in ["Needs Keep history", "Output/", "Reopen Last Image", "Save styled output", "reusing the file",
                       "Raw/ is never touched", "Save untouched raw capture"] {
            #expect(keep.contains(phrase), "keep caption lacks “\(phrase)”")
        }

        let period = OutputRetentionSection.periodDetail
        for phrase in ["Forever never removes anything", "Trash", "only ones Glint saved to Output/ after you opted in",
                       "Existing files", "Raw/", "save or export yourself", "left alone"] {
            #expect(period.contains(phrase), "period caption lacks “\(phrase)”")
        }

        #expect(OutputRetentionSection.keepPausedDetail.contains("Needs Keep history, which is off"))
        #expect(OutputRetentionSection.keepPausedDetail.contains("never turns it on for you"))
        #expect(OutputRetentionSection.periodPausedDetail.contains("Needs Keep history, which is off"))
        #expect(OutputRetentionSection.periodPausedDetail.contains("Nothing is removed"))
    }

    @MainActor
    private struct Fixture {
        let suite = "OutputRetentionPreferencesTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let prefs: AppPreferences
        let model: PrefsModel

        init() {
            defaults = UserDefaults(suiteName: suite)!
            prefs = AppPreferences(defaults: defaults)
            // /dev/null is not a directory, so the preset store can neither load from nor save to this path.
            model = PrefsModel(prefs: prefs, store: PresetStore(url: URL(fileURLWithPath: "/dev/null/presets.json")))
        }

        /// A new instance over the same suite, as after a restart.
        var persisted: AppPreferences { AppPreferences(defaults: UserDefaults(suiteName: suite)!) }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}
