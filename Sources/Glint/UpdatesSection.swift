import GlintCore
import SwiftUI

/// The About tab's "Updates" block: schedule, manual check, last check, and — for copies Homebrew or a missing
/// signing key keep from updating themselves — what to do instead.
struct UpdatesSection: View {
    @ObservedObject var updater: UpdateController
    // `@State` needs the SwiftUI macro plugin, which Command Line Tools builds lack; `Local` is the house substitute.
    @StateObject private var copied = Local<Bool>(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates").font(.headline)
            switch updater.availability {
            case .ready:
                ready
            case .homebrew(let hint):
                homebrew(hint: hint)
            case .unavailable(let reason):
                unavailable(reason)
            }
            Link("How updates work, and moving between Homebrew and a download", destination: UpdateController.guideURL)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Check for updates automatically", selection: Binding(
                get: { updater.frequency },
                set: { updater.setFrequency($0) }
            )) {
                ForEach(UpdateCheckFrequency.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            HStack(spacing: 10) {
                Button("Check Now") { updater.checkForUpdates(nil) }
                    .disabled(!updater.canCheckNow)
                Text(lastCheckText).foregroundStyle(.secondary)
            }
            Text("Automatic checks are off until you pick a schedule. Glint always asks before it downloads or installs an update, and verifies every update’s signature first.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastCheckText: String {
        guard let last = updater.lastCheck else { return "Last checked: never" }
        return "Last checked: \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    private func homebrew(hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This copy of Glint was installed with Homebrew, so Homebrew keeps it up to date. Save your edits and quit Glint, then run this in Terminal:")
                .fixedSize(horizontal: false, vertical: true)
            Text(UpdateInstallSource.homebrewUpdateCommand)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Button(copied.value ? "Copied" : "Copy Command") {
                copied.value = UpdateController.copy(UpdateInstallSource.homebrewUpdateCommand)
            }
            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This copy of Glint can’t update itself. \(reason)")
                .fixedSize(horizontal: false, vertical: true)
            Link("Open the Releases Page", destination: UpdateController.releasesURL)
        }
    }
}
