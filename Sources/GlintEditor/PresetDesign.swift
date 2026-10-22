import AppKit
import GlintCore
import SwiftUI

/// What the preset designer edits.
public struct PresetDesign {
    /// Preview image (sample or the user's own); never saved.
    public var image: CGImage
    public var backingScale: CGFloat
    /// Starting look.
    public var settings: RenderSettings
    /// Prefilled preset name.
    public var name: String
    /// Existing preset to update; nil creates a new preset.
    public var editingID: UUID?

    public init(image: CGImage, backingScale: CGFloat, settings: RenderSettings, name: String, editingID: UUID? = nil) {
        self.image = image
        self.backingScale = backingScale
        self.settings = settings
        self.name = name
        self.editingID = editingID
    }
}

enum PresetDesignError: LocalizedError, Equatable {
    case notDesigning, emptyName, duplicateName

    var errorDescription: String? {
        switch self {
        case .notDesigning: return "This editor isn't designing a preset."
        case .emptyName: return "Enter a name for the preset."
        case .duplicateName: return "A preset with this name already exists."
        }
    }
}

extension EditorModel {
    var isDesigningPreset: Bool { design != nil }

    /// The stored preset being edited, or nil when creating one (including when it was deleted meanwhile).
    var designEditingPreset: Preset? {
        design?.editingID.flatMap { id in presetStore.presets.first { $0.id == id } }
    }

    /// The preset new captures use: the one named in preferences, else the store's default.
    var effectiveDefaultPreset: Preset? {
        preferences.defaultPresetName.flatMap { presetStore.preset(named: $0) } ?? presetStore.defaultPreset
    }

    var designIsDefault: Bool {
        guard let editing = designEditingPreset else { return false }
        return effectiveDefaultPreset?.id == editing.id
    }

    var designTitle: String {
        designEditingPreset.map { "Edit Preset “\($0.name)”" } ?? "New Preset"
    }

    private var trimmedDesignName: String { designName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var designNameTaken: Bool {
        let name = trimmedDesignName, id = designEditingPreset?.id
        return presetStore.presets.contains { $0.name == name && $0.id != id }
    }

    var designValidationMessage: String? {
        !trimmedDesignName.isEmpty && designNameTaken ? PresetDesignError.duplicateName.errorDescription : nil
    }

    var canSaveDesign: Bool { isDesigningPreset && !trimmedDesignName.isEmpty && !designNameTaken }

    /// Creates or updates the designed preset and persists the store; on failure nothing changes.
    @discardableResult
    func saveDesignedPreset() throws -> Preset {
        guard isDesigningPreset else { throw PresetDesignError.notDesigning }
        let name = trimmedDesignName
        guard !name.isEmpty else { throw PresetDesignError.emptyName }
        guard !designNameTaken else { throw PresetDesignError.duplicateName }
        let oldDefaultID = presetStore.defaultPresetID, oldDefaultName = preferences.defaultPresetName
        let original = designEditingPreset
        let saved: Preset
        if let original {
            saved = Preset(id: original.id, name: name, settings: settings)
            presetStore.update(saved)
            if oldDefaultName == original.name { preferences.defaultPresetName = name }
        } else {
            saved = presetStore.add(name: name, settings: settings)
        }
        if designMakeDefault {
            presetStore.setDefault(id: saved.id)
            preferences.defaultPresetName = name
        }
        do {
            try presetStore.save()
        } catch {
            if let original { presetStore.update(original) } else { presetStore.delete(id: saved.id) }
            presetStore.defaultPresetID = oldDefaultID
            preferences.defaultPresetName = oldDefaultName
            throw error
        }
        refreshPresets()
        return saved
    }
}

// MARK: - Designer chrome

struct PresetDesignHeaderView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paintpalette").foregroundStyle(.secondary)
            Text(model.designTitle).font(.headline)
            Text("Adjust the look in the sidebar, then save it as a preset. The preview image isn't saved.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
    }
}

struct PresetDesignBarView: View {
    @ObservedObject var model: EditorModel
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 10) {
            TextField("Preset name", text: $model.designName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { actions.savePreset() }
                .accessibilityLabel("Preset name")
            Toggle("Set as default", isOn: $model.designMakeDefault)
                .toggleStyle(.checkbox)
                .disabled(model.designIsDefault)
                .help(model.designIsDefault ? "This is already the default preset" : "Use this preset for new screenshots")
            if let problem = model.designValidationMessage {
                Text(problem).font(.caption).foregroundStyle(.red).lineLimit(1).help(problem)
            } else if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(status)
            }
            Spacer()
            Button("Cancel") { actions.close() }
                .keyboardShortcut(.cancelAction)
                .help("Close without saving (Esc)")
            // Return is routed by the window controller / name field so other sidebar fields keep their own Return.
            Button("Save Preset") { actions.savePreset() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSaveDesign)
                .help("Save Preset (⌘S or Return)")
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(.bar)
    }
}
