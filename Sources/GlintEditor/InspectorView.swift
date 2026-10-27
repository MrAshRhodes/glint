import AppKit
import GlintCore
import SwiftUI

enum SwatchRenderer {
    private static var cache: [String: NSImage] = [:]

    static func image(id: String, style: GlintCore.BackgroundStyle) -> NSImage {
        if let c = cache[id] { return c }
        let blank = GlintBitmap.makeContext(width: 64, height: 64)?.makeImage()
        var out = NSImage(size: CGSize(width: 32, height: 32))
        let s = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none, background: style,
                               aspectRatio: .auto, autoBalance: false)
        if let blank, let r = try? Compositor.render(image: blank, settings: s, backingScale: 1) {
            out = NSImage(cgImage: r, size: CGSize(width: 32, height: 32))
        }
        cache[id] = out
        return out
    }
}

/// Inspector sections whose expanded state is persisted across launches.
enum InspectorSectionID: String, CaseIterable {
    case preset, selection, background, layout, ratio, frame, transform, redact, text, watermark

    /// UserDefaults key holding whether the section is expanded.
    var storageKey: String { "inspector.section.\(rawValue).expanded" }

    var defaultExpanded: Bool {
        switch self {
        case .preset, .selection, .background, .layout: return true
        case .ratio, .frame, .transform, .redact, .text, .watermark: return false
        }
    }

    var symbol: String {
        switch self {
        case .preset: return "square.stack.3d.up"
        case .selection: return "paintbrush.pointed"
        case .background: return "paintpalette"
        case .layout: return "square.dashed"
        case .ratio: return "aspectratio"
        case .frame: return "macwindow"
        case .transform: return "rotate.right"
        case .redact: return "eye.slash"
        case .text: return "text.viewfinder"
        case .watermark: return "signature"
        }
    }
}

/// Collapsible inspector group: a header button over a grouped card (never glass on glass).
private struct CollapsibleSection<Content: View>: View {
    let title: String
    let symbol: String?
    let summary: String?
    @Binding var isExpanded: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, symbol: String? = nil, summary: String? = nil, isExpanded: Binding<Bool>,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self._isExpanded = isExpanded
        self.content = content()
    }

    private var collapsedSummary: String? {
        guard !isExpanded, let summary, !summary.isEmpty else { return nil }
        return summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                    }
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let collapsedSummary {
                        Text(collapsedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsedSummary.map { "\(title), \($0)" } ?? title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isHeader)
            .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")

            if isExpanded {
                VStack(alignment: .leading, spacing: GlintDesign.rowSpacing) {
                    content
                }
                .font(.callout)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .glintCard()
                .transition(.opacity)
            }
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
                    .accessibilityHidden(true)
            }
            Slider(value: $value, in: range).accessibilityLabel(title).accessibilityValue(format(value))
        }
    }
}

/// Caption-sized warning with an orange triangle, used for unsafe redaction and wallpaper problems.
private struct InspectorWarning: View {
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
    }
}

final class InspectorState: ObservableObject {
    @Published var presetName = ""
    @Published var showSavePreset = false
    @Published var renameTarget: Preset?
    @Published var renameText = ""
    @Published var customRatio = ""
    @Published var showText = false
}

struct InspectorView: View {
    @ObservedObject var model: EditorModel
    // CLT-only builds lack the SwiftUI macro plugin, so local state lives in an ObservableObject instead of @State.
    @StateObject private var ui = InspectorState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Expanded state per section, shared by every editor window and persisted across launches.
    @AppStorage("inspector.section.preset.expanded") private var presetExpanded = true
    @AppStorage("inspector.section.selection.expanded") private var selectionExpanded = true
    @AppStorage("inspector.section.background.expanded") private var backgroundExpanded = true
    @AppStorage("inspector.section.layout.expanded") private var layoutExpanded = true
    @AppStorage("inspector.section.ratio.expanded") private var ratioExpanded = false
    @AppStorage("inspector.section.frame.expanded") private var frameExpanded = false
    @AppStorage("inspector.section.transform.expanded") private var transformExpanded = false
    @AppStorage("inspector.section.redact.expanded") private var redactExpanded = false
    @AppStorage("inspector.section.text.expanded") private var textExpanded = false
    @AppStorage("inspector.section.watermark.expanded") private var watermarkExpanded = false

    private var s: Binding<RenderSettings> { Binding(get: { model.settings }, set: { model.settings = $0 }) }

    private var showsAnnotationSection: Bool {
        !model.isDesigningPreset && (!model.selection.isEmpty || model.tool != .select)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    presetsSection
                    if !model.isDesigningPreset, !model.selection.isEmpty || (model.tool != .select) {
                        annotationSection
                    }
                    backgroundSection
                    sizeSection
                    ratioSection
                    frameSection
                    transformSection
                    if !model.isDesigningPreset {
                        redactSection
                        textSection
                    }
                    watermarkSection
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 300)
    }

    // MARK: Header / expansion

    private var visibleSections: [InspectorSectionID] {
        InspectorSectionID.allCases.filter { id in
            switch id {
            case .selection: return showsAnnotationSection
            case .redact, .text: return !model.isDesigningPreset
            default: return true
            }
        }
    }

    private var anyExpanded: Bool { visibleSections.contains { expanded(id: $0).wrappedValue } }

    private var header: some View {
        let collapse = anyExpanded
        return HStack(spacing: 8) {
            Text(model.isDesigningPreset ? "Preset style" : "Style")
                .font(.headline)
            Spacer()
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                    for id in InspectorSectionID.allCases { expanded(id: id).wrappedValue = !collapse }
                }
            } label: {
                Image(systemName: collapse ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(collapse ? "Collapse all sections" : "Expand all sections")
            .accessibilityLabel(collapse ? "Collapse All" : "Expand All")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func expanded(id: InspectorSectionID) -> Binding<Bool> {
        switch id {
        case .preset: return $presetExpanded
        case .selection: return $selectionExpanded
        case .background: return $backgroundExpanded
        case .layout: return $layoutExpanded
        case .ratio: return $ratioExpanded
        case .frame: return $frameExpanded
        case .transform: return $transformExpanded
        case .redact: return $redactExpanded
        case .text: return $textExpanded
        case .watermark: return $watermarkExpanded
        }
    }

    private func section<Content: View>(_ id: InspectorSectionID, _ title: String, summary: String? = nil,
                                         @ViewBuilder content: () -> Content) -> some View {
        CollapsibleSection(title, symbol: id.symbol, summary: summary, isExpanded: expanded(id: id), content: content)
    }

    // MARK: Presets

    private var presetsSection: some View {
        section(.preset, "Preset", summary: model.settings.autoBalance ? "Auto-balance" : nil) {
            HStack {
                Menu {
                    ForEach(model.presets) { p in
                        Button(p.id == model.defaultPresetID ? "\(p.name) (default)" : p.name) { model.applyPreset(p) }
                    }
                    if !model.isDesigningPreset {
                        Divider()
                        Button("Save Current as Preset…") { ui.presetName = ""; ui.showSavePreset = true }
                        Menu("Rename") {
                            ForEach(model.presets) { p in Button(p.name) { ui.renameText = p.name; ui.renameTarget = p } }
                        }
                        Menu("Set as Default") {
                            ForEach(model.presets) { p in Button(p.name) { model.setDefaultPreset(p) } }
                        }
                        Menu("Delete") {
                            ForEach(model.presets) { p in Button(p.name, role: .destructive) { model.deletePreset(p) } }
                        }
                    }
                } label: { Text(model.isDesigningPreset ? "Start From" : "Presets") }
                .fixedSize()
                .help(model.isDesigningPreset ? "Use an existing preset as the starting point" : "Apply or manage presets")
                .popover(isPresented: $ui.showSavePreset, arrowEdge: .bottom) {
                    nameInput(title: "Save preset", text: $ui.presetName, action: "Save") {
                        model.savePreset(named: ui.presetName); ui.showSavePreset = false
                    }
                }
                .popover(item: $ui.renameTarget, arrowEdge: .bottom) { target in
                    nameInput(title: "Rename preset", text: $ui.renameText, action: "Rename") {
                        model.renamePreset(target, to: ui.renameText); ui.renameTarget = nil
                    }
                }
                Spacer()
                Toggle("Auto-balance", isOn: s.autoBalance).toggleStyle(.switch).controlSize(.mini)
                    .help("Crop uniform borders and even out the margins")
            }
        }
    }

    private func nameInput(title: String, text: Binding<String>, action: String, run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            TextField("Preset name", text: text).frame(width: 200).onSubmit(run)
            HStack { Spacer(); Button(action, action: run).keyboardShortcut(.defaultAction).disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(12)
    }

    // MARK: Annotation properties

    private var currentStyle: AnnotationStyle { model.selectedAnnotations.first?.style ?? model.defaultStyle }

    private var annotationSection: some View {
        let scale = Double(model.backingScale)
        let sel = model.selectedAnnotations
        let isText = sel.isEmpty ? model.tool == .text : sel.allSatisfy { $0.kind.isText }
        let modes = model.activeRedactionModes
        let hasShape = sel.contains { if case .rectangle = $0.kind { return true }; if case .ellipse = $0.kind { return true }; return false }
            || (sel.isEmpty && model.tool == .shape)
        return section(.selection, sel.isEmpty ? "New \(model.tool.title.lowercased()) style" : "Selection (\(sel.count))") {
            if model.tool == .redact || !modes.isEmpty {
                RedactionModePicker(model: model)
            }
            if model.showsObfuscationWarning {
                InspectorWarning(text: "Blur is obfuscation, not secure redaction. Information may be recoverable. Use Solid or Pixelate for secrets.")
            }
            if modes.isEmpty {
                SliderRow(title: isText ? "Font size" : "Stroke", value: Binding(
                    get: { (isText ? currentStyle.fontSize : currentStyle.strokeWidth) / scale },
                    set: { v in model.updateStyle(key: "size") { if isText { $0.fontSize = v * scale } else { $0.strokeWidth = v * scale } } }),
                          range: isText ? 8...160 : 1...40)
                SliderRow(title: "Opacity", value: Binding(
                    get: { currentStyle.opacity * 100 },
                    set: { v in model.updateStyle(key: "opacity") { $0.opacity = v / 100 } }), range: 10...100)
            }
            if isText {
                Toggle("Bold", isOn: Binding(get: { currentStyle.bold }, set: { v in model.updateStyle(key: "bold") { $0.bold = v } }))
                    .toggleStyle(.checkbox)
            }
            if modes.contains(.blur) {
                SliderRow(title: "Blur intensity", value: Binding(
                    get: { model.redactionAppearance(for: .blur).intensity / scale },
                    set: { model.setBlurIntensity($0 * scale) }), range: 2...60)
            }
            if modes.contains(.solid) {
                solidRedactionControls
            }
            if modes.contains(.pixelate) {
                pixelateControls
            }
            if model.showsMagnifierControls && modes.isEmpty {
                magnifierControls
            }
            if hasShape && modes.isEmpty {
                HStack(spacing: 16) {
                    Toggle("Dashed", isOn: Binding(get: { currentStyle.dashed }, set: { v in model.updateStyle(key: "dash") { $0.dashed = v } }))
                        .toggleStyle(.checkbox)
                    Toggle("Filled", isOn: Binding(
                        get: { currentStyle.fill != nil },
                        set: { v in model.updateStyle(key: "fill") { st in st.fill = v ? st.color.with(alpha: 0.25) : nil } }))
                        .toggleStyle(.checkbox)
                }
            }
            if !sel.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Button { model.reorder(.back) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                        .help("Send to back").accessibilityLabel("Send to back")
                    Button { model.reorder(.backward) } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }
                        .help("Send backward (⌘[)").accessibilityLabel("Send backward")
                    Button { model.reorder(.forward) } label: { Image(systemName: "square.2.layers.3d.top.filled") }
                        .help("Bring forward (⌘])").accessibilityLabel("Bring forward")
                    Button { model.reorder(.front) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                        .help("Bring to front").accessibilityLabel("Bring to front")
                    Spacer()
                    Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate (⌘D)").accessibilityLabel("Duplicate")
                    Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }
                        .help("Delete (⌫)").accessibilityLabel("Delete")
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var magnifierControls: some View {
        VStack(alignment: .leading, spacing: GlintDesign.rowSpacing) {
            Picker("Shape", selection: Binding(get: { model.currentMagnifierShape }, set: { model.setMagnifierShape($0) })) {
                Text("Circle").tag(MagnifierShape.circle)
                Text("Rectangle").tag(MagnifierShape.rectangle)
            }
            .pickerStyle(.segmented)
            SliderRow(title: "Magnification", value: Binding(
                get: { model.currentMagnification },
                set: { model.setMagnification($0) }),
                      range: AnnotationGeometry.magnificationRange,
                      format: { "\((($0 * 100).rounded() / 100).formatted())×" })
            Toggle("Show source outline", isOn: Binding(
                get: { model.currentMagnifierShowsSourceOutline },
                set: { model.setMagnifierShowsSourceOutline($0) }))
                .toggleStyle(.checkbox)
            Toggle("Connect to source", isOn: Binding(
                get: { model.currentMagnifierShowsConnector },
                set: { model.setMagnifierShowsConnector($0) }))
                .toggleStyle(.checkbox)
        }
    }

    private var solidRedactionControls: some View {
        let style = model.redactionAppearance(for: .solid)
        return VStack(alignment: .leading, spacing: GlintDesign.rowSpacing) {
            Picker("Solid pattern", selection: Binding(
                get: { model.redactionAppearance(for: .solid).redactionPattern },
                set: { model.setRedactPattern($0) })) {
                    Text("Plain").tag(RedactionPattern.plain)
                    Text("Checkerboard").tag(RedactionPattern.checkerboard)
                }
                .pickerStyle(.segmented)
                .help("Both patterns fully replace the covered pixels with opaque colours")
            ColorPicker(style.redactionPattern == .checkerboard ? "Foreground colour" : "Redaction colour",
                        selection: colorBinding({ model.redactionAppearance(for: .solid).color }) { model.setRedactColor($0) },
                        supportsOpacity: false)
            if style.redactionPattern == .checkerboard {
                ColorPicker("Background colour",
                            selection: colorBinding({ model.redactionAppearance(for: .solid).redactionSecondaryColor }) {
                    model.setRedactSecondaryColor($0)
                }, supportsOpacity: false)
                redactionCellSize(for: .solid)
            }
        }
    }

    private var pixelateControls: some View {
        VStack(alignment: .leading, spacing: GlintDesign.rowSpacing) {
            Text("Opaque decorative mosaic. Original pixels are replaced, not sampled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Highlight with redaction colour", isOn: Binding(
                get: { model.redactionAppearance(for: .pixelate).pixelateHighlight },
                set: { model.setPixelateHighlight($0) }))
                .toggleStyle(.checkbox)
                .help("Use the selected redaction colour as an accent in the secure mosaic")
            if model.redactionAppearance(for: .pixelate).pixelateHighlight {
                ColorPicker("Highlight colour",
                            selection: colorBinding({ model.redactionAppearance(for: .pixelate).color }) { model.setRedactColor($0) },
                            supportsOpacity: false)
            }
            redactionCellSize(for: .pixelate)
        }
    }

    private func redactionCellSize(for mode: RedactionStyle) -> some View {
        let scale = Double(model.backingScale)
        return SliderRow(title: mode == .solid ? "Checkerboard cell size" : "Pixelate cell size", value: Binding(
            get: { model.redactionAppearance(for: mode).intensity / scale },
            set: { model.setRedactCellSize($0 * scale) }), range: 2...60)
    }

    // MARK: Background

    private var backgroundSummary: String {
        if model.settings.usesDesktopWallpaper { return "Wallpaper" }
        let bg = model.settings.background
        if let preset = BackgroundCatalog.all.first(where: { $0.style == bg }) { return preset.name }
        switch bg {
        case .transparent: return "None"
        case .solid: return "Solid colour"
        case .linear: return "Custom gradient"
        case .mesh: return "Mesh gradient"
        case .pattern: return "Pattern"
        case .image: return "Image"
        }
    }

    private var backgroundSection: some View {
        section(.background, "Background", summary: backgroundSummary) {
            Toggle("Use desktop wallpaper", isOn: s.usesDesktopWallpaper)
                .toggleStyle(.checkbox)
            if model.settings.usesDesktopWallpaper {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Main display, current Space. Toggle off and on to refresh.")
                    Text("Dynamic wallpapers use their primary still image.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.wallpaperProblem {
                InspectorWarning(text: problem)
            }
            let cols = Array(repeating: GridItem(.flexible(minimum: 30), spacing: 8), count: 6)
            LazyVGrid(columns: cols, alignment: .center, spacing: 10) {
                swatch(id: "none", name: "None", style: .transparent, selected: model.settings.background == .transparent)
                ForEach(BackgroundCatalog.all) { p in
                    swatch(id: p.id, name: p.name, style: p.style, selected: model.settings.background == p.style)
                }
            }
            .padding(.vertical, 2)
            HStack {
                ColorPicker("Solid colour", selection: colorBinding({
                    if case .solid(let c) = model.settings.background { return c }
                    return .white
                }) { model.chooseBackground(.solid($0)) }, supportsOpacity: false)
                Spacer()
                Button("Image…") { chooseBackgroundImage() }
            }
            if case .linear(let g) = model.settings.background, let first = g.stops.first, let last = g.stops.last {
                Divider()
                HStack {
                    ColorPicker("From", selection: colorBinding({ first.color }) { c in
                        var n = g; n.stops[0].color = c; model.chooseBackground(.linear(n)) }, supportsOpacity: false)
                    Spacer()
                    ColorPicker("To", selection: colorBinding({ last.color }) { c in
                        var n = g; n.stops[n.stops.count - 1].color = c; model.chooseBackground(.linear(n)) }, supportsOpacity: false)
                }
                SliderRow(title: "Gradient angle", value: Binding(get: { g.angle }, set: { v in
                    var n = g; n.angle = v; model.chooseBackground(.linear(n)) }), range: 0...360) { "\(Int($0))°" }
            } else {
                Button("Custom gradient") {
                    model.chooseBackground(.linear(LinearGradient(angle: 135, hexes: ["#6A11CB", "#2575FC"])))
                }
            }
        }
    }

    private func swatch(id: String, name: String, style: GlintCore.BackgroundStyle, selected: Bool) -> some View {
        let selected = selected && !model.settings.usesDesktopWallpaper
        let radius = GlintDesign.controlCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Button { model.chooseBackground(style) } label: {
            Group {
                if style == .transparent {
                    Image(systemName: "nosign").foregroundStyle(.secondary).frame(width: 30, height: 30)
                        .background(shape.fill(.quaternary))
                } else {
                    Image(nsImage: SwatchRenderer.image(id: id, style: style)).resizable().frame(width: 30, height: 30)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .overlay {
                // Selection ring sits outside the swatch with a 2pt gap, concentric with its corners.
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Background \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selected)
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.chooseBackground(.image(path: url.path, fit: .fill))
        }
    }

    // MARK: Sliders

    private var sizeSection: some View {
        section(.layout, "Layout", summary: "Padding \(Int(model.settings.padding.rounded()))") {
            SliderRow(title: "Padding", value: s.padding, range: 0...300)
            SliderRow(title: "Inset", value: s.inset, range: 0...200)
            SliderRow(title: "Rounded", value: s.cornerRadius, range: 0...50)
            SliderRow(title: "Shadow", value: Binding(get: { model.settings.shadow.strength }, set: {
                model.settings.shadow.strength = $0; model.settings.shadow.enabled = $0 > 0 }), range: 0...100)
            Divider()
            HStack {
                Text("3D tilt").font(.callout)
                Spacer()
                Button("Reset") { model.settings.tilt = .zero }
                    .disabled(model.settings.tilt == .zero)
            }
            SliderRow(title: "Tilt X", value: Binding(get: { model.settings.tilt.x + 15 }, set: { model.settings.tilt = Tilt(uiX: $0, uiY: model.settings.tilt.y + 15) }), range: 0...30)
            SliderRow(title: "Tilt Y", value: Binding(get: { model.settings.tilt.y + 15 }, set: { model.settings.tilt = Tilt(uiX: model.settings.tilt.x + 15, uiY: $0) }), range: 0...30)
        }
    }

    // MARK: Ratio

    private var ratioSection: some View {
        section(.ratio, "Ratio", summary: shortName(model.settings.aspectRatio)) {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(AspectRatioPreset.allBuiltIn, id: \.self) { r in
                    let selected = model.settings.aspectRatio == r
                    Button { model.settings.aspectRatio = r } label: {
                        Text(shortName(r)).font(.caption).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(selected ? .accentColor : nil)
                    .help(r.displayName)
                    .accessibilityLabel("Ratio \(r.displayName)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            HStack(spacing: 6) {
                TextField("Custom 4:3 or 1200x630", text: $ui.customRatio).textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustomRatio)
                Button("Set", action: applyCustomRatio)
            }
        }
    }

    private func shortName(_ r: AspectRatioPreset) -> String {
        switch r {
        case .twitterPost: return "X Post"
        case .twitterHeader: return "X Header"
        case .linkedInPost: return "LinkedIn"
        case .instagramSquare: return "IG 1:1"
        case .instagramPortrait: return "IG 4:5"
        case .facebookPost: return "Facebook"
        case .youTubeThumbnail: return "YouTube"
        case .openGraph: return "OG"
        case .pinterestPin: return "Pinterest"
        case .redditPost: return "Reddit"
        case .snapchatStory: return "Snapchat"
        default: return r.displayName
        }
    }

    private func applyCustomRatio() {
        if let r = AspectRatioPreset.parse(ui.customRatio) { model.settings.aspectRatio = r } else { NSSound.beep() }
    }

    // MARK: Frame / transform

    private var frameSection: some View {
        section(.frame, "Frame", summary: model.settings.windowFrame.style.displayName) {
            Picker("Style", selection: s.windowFrame.style) {
                Text(WindowFrameKind.none.displayName).tag(WindowFrameKind.none)
                ForEach(WindowFrameCategory.allCases, id: \.self) { category in
                    SwiftUI.Section(category.displayName) {
                        ForEach(WindowFrameKind.allCases.filter { $0.category == category }, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                }
            }
            .pickerStyle(.menu).labelsHidden()
            .accessibilityLabel("Frame style")
            let frame = model.settings.windowFrame
            if frame.style != .none {
                TextField(frame.style.titlePlaceholder, text: s.windowFrame.title).textFieldStyle(.roundedBorder)
                HStack(spacing: 16) {
                    Toggle("Dark", isOn: s.windowFrame.dark).toggleStyle(.checkbox)
                    if frame.metrics.supportsScreenEffects {
                        Toggle("Screen effects", isOn: s.windowFrame.screenEffects).toggleStyle(.checkbox)
                            .help("Subtle scanlines and glare")
                    }
                }
            }
            Toggle("Outline border", isOn: s.border.enabled).toggleStyle(.checkbox)
        }
    }

    private var transformSummary: String? {
        let st = model.settings
        var parts: [String] = []
        if st.rotation != .none { parts.append("\(st.rotation.rawValue)°") }
        if st.flipHorizontal || st.flipVertical { parts.append("Flipped") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var transformSection: some View {
        section(.transform, "Transform", summary: transformSummary) {
            HStack(spacing: 6) {
                Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .help("Rotate left").accessibilityLabel("Rotate left")
                Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .help("Rotate right").accessibilityLabel("Rotate right")
                Button { model.settings.flipHorizontal.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Flip horizontally").accessibilityLabel("Flip horizontally")
                Button { model.settings.flipVertical.toggle() } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                    .help("Flip vertically").accessibilityLabel("Flip vertically")
                Spacer()
            }
            if !model.isEditable, !model.isDesigningPreset {
                Text("Annotations are paused while rotated, flipped or tilted.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Redact

    private var redactSection: some View {
        let count = model.redactOptions.categories.count
        return section(.redact, "Auto-redact", summary: count == 0 ? "Off" : "\(count) categor\(count == 1 ? "y" : "ies")") {
            let cats = SensitiveCategory.allCases
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(cats, id: \.self) { c in
                    Toggle(c.displayName, isOn: Binding(
                        get: { model.redactOptions.categories.contains(c) },
                        set: { on in
                            if on { model.redactOptions.categories.insert(c) } else { model.redactOptions.categories.remove(c) }
                            model.preferences.autoRedactOptions = model.redactOptions
                        })).toggleStyle(.checkbox).font(.caption)
                }
            }
            TextField("Custom words (comma separated)", text: Binding(
                get: { model.redactOptions.customWords.joined(separator: ", ") },
                set: { v in
                    model.redactOptions.customWords = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.preferences.autoRedactOptions = model.redactOptions
                })).textFieldStyle(.roundedBorder)
            Text("Auto-redact always uses solid fill. Review the image before sharing; detection can miss information.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                ColorPicker("Colour", selection: colorBinding({ model.redactColor }) { model.setRedactColor($0) }, supportsOpacity: false)
                Spacer()
            }
            Toggle("Auto-redact new screenshots", isOn: Binding(
                get: { model.preferences.autoRedact }, set: { model.preferences.autoRedact = $0 }))
                .toggleStyle(.switch).controlSize(.mini)
            Divider()
            HStack {
                Button("Redact Sensitive Info") { Task { await model.runAutoRedact() } }.disabled(model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            if let summary = model.lastRedactSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: OCR

    private var textSection: some View {
        section(.text, "Text in image", summary: model.ocrLines.isEmpty ? nil : "\(model.ocrLines.count) lines") {
            HStack {
                Button("Detect Text") { Task { await model.detectText(); ui.showText = true } }.disabled(model.isBusy)
                Button("Copy Text") {
                    Task {
                        if model.ocrLines.isEmpty { await model.detectText() }
                        model.copyText()
                    }
                }.disabled(model.isBusy)
            }
            if !model.ocrLines.isEmpty {
                DisclosureGroup("\(model.ocrLines.count) lines", isExpanded: $ui.showText) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.ocrLines.prefix(60).enumerated()), id: \.offset) { _, line in
                            Button { model.copyText(line.text) } label: {
                                Text(line.text).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Copy this line")
                        }
                    }
                }
            }
        }
    }

    // MARK: Watermark

    private var watermarkSection: some View {
        section(.watermark, "Watermark", summary: model.settings.watermark.enabled ? "On" : "Off") {
            Toggle("Show watermark", isOn: s.watermark.enabled).toggleStyle(.switch).controlSize(.mini)
            if model.settings.watermark.enabled {
                HStack(spacing: 6) {
                    TextField("Text", text: s.watermark.text).textFieldStyle(.roundedBorder)
                    Menu("Templates") {
                        ForEach(["Screenshot by Glint", "Made with Glint", "© \(Calendar.current.component(.year, from: Date()))", "@yourhandle"], id: \.self) { t in
                            Button(t) { model.settings.watermark.text = t; model.settings.watermark.kind = .text }
                        }
                        Divider()
                        Button("Image…") { chooseWatermarkImage() }
                    }
                    .fixedSize()
                }
                Picker("Position", selection: s.watermark.position) {
                    ForEach(WatermarkPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                SliderRow(title: "Opacity", value: Binding(get: { model.settings.watermark.opacity * 100 }, set: { model.settings.watermark.opacity = $0 / 100 }), range: 10...100)
                SliderRow(title: "Size", value: s.watermark.size, range: 8...64)
                ColorPicker("Colour", selection: colorBinding({ model.settings.watermark.color }) { model.settings.watermark.color = $0 }, supportsOpacity: false)
            }
        }
    }

    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.watermark.imagePath = url.path
            model.settings.watermark.kind = .image
        }
    }
}
