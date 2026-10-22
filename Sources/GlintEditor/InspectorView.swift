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

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content
        }
        .padding(.vertical, 10)
        Divider()
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(format(value)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    .accessibilityHidden(true)
            }
            Slider(value: $value, in: range).accessibilityLabel(title).accessibilityValue(format(value))
        }
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

    private var s: Binding<RenderSettings> { Binding(get: { model.settings }, set: { model.settings = $0 }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 300)
        .background(.regularMaterial)
    }

    // MARK: Presets

    private var presetsSection: some View {
        Section(title: "Preset") {
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
                Toggle("Auto-balance", isOn: s.autoBalance).toggleStyle(.switch).controlSize(.small)
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
        let hasBlur = sel.contains { $0.isObfuscation }
        let isDrawingObfuscation = sel.isEmpty && model.tool == .redact && model.redactStyle.isObfuscation
        let hasSolidRedact = sel.contains { $0.isRedaction }
            || (sel.isEmpty && model.tool == .redact && model.redactStyle == .solid)
        let hasShape = sel.contains { if case .rectangle = $0.kind { return true }; if case .ellipse = $0.kind { return true }; return false }
            || (sel.isEmpty && model.tool == .shape)
        return Section(title: sel.isEmpty ? "New \(model.tool.title.lowercased()) style" : "Selection (\(sel.count))") {
            if model.tool == .redact {
                Picker("Manual mode", selection: $model.redactStyle) {
                    ForEach(RedactionStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.menu)
            }
            if model.showsObfuscationWarning {
                Label("Blur and pixelate are obfuscation, not secure redaction. Information may be recoverable. Use Solid redaction for secrets.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hasBlur && !hasSolidRedact && !isDrawingObfuscation {
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
            if hasBlur {
                SliderRow(title: "Intensity", value: Binding(
                    get: { currentStyle.intensity / scale },
                    set: { v in model.updateStyle(key: "intensity") { $0.intensity = v * scale } }), range: 2...60)
            }
            if hasSolidRedact {
                HStack {
                    Text("Redaction colour").font(.system(size: 12))
                    Spacer()
                    ColorPicker("Redaction colour", selection: colorBinding({ model.redactColor }) { model.setRedactColor($0) }, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            if hasShape {
                Toggle("Dashed", isOn: Binding(get: { currentStyle.dashed }, set: { v in model.updateStyle(key: "dash") { $0.dashed = v } }))
                    .toggleStyle(.checkbox)
                Toggle("Filled", isOn: Binding(
                    get: { currentStyle.fill != nil },
                    set: { v in model.updateStyle(key: "fill") { st in st.fill = v ? st.color.with(alpha: 0.25) : nil } }))
                    .toggleStyle(.checkbox)
            }
            if !sel.isEmpty {
                HStack(spacing: 6) {
                    Button { model.reorder(.back) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }.help("Send to back")
                    Button { model.reorder(.backward) } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }.help("Send backward (⌘[)")
                    Button { model.reorder(.forward) } label: { Image(systemName: "square.2.layers.3d.top.filled") }.help("Bring forward (⌘])")
                    Button { model.reorder(.front) } label: { Image(systemName: "square.3.layers.3d.top.filled") }.help("Bring to front")
                    Spacer()
                    Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
                    Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }.help("Delete (⌫)")
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    // MARK: Background

    private var backgroundSection: some View {
        Section(title: "Background") {
            Toggle("Use desktop wallpaper", isOn: s.usesDesktopWallpaper)
                .toggleStyle(.checkbox)
            if model.settings.usesDesktopWallpaper {
                Text("Main display, current Space. Toggle off and on to refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Dynamic wallpapers use their primary still image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = model.wallpaperProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let cols = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
                swatch(id: "none", name: "None", style: .transparent, selected: model.settings.background == .transparent)
                ForEach(BackgroundCatalog.all) { p in
                    swatch(id: p.id, name: p.name, style: p.style, selected: model.settings.background == p.style)
                }
            }
            HStack {
                ColorPicker("Solid colour", selection: colorBinding({
                    if case .solid(let c) = model.settings.background { return c }
                    return .white
                }) { model.chooseBackground(.solid($0)) }, supportsOpacity: false)
                    .font(.system(size: 12))
                Spacer()
                Button("Image…") { chooseBackgroundImage() }
            }
            if case .linear(let g) = model.settings.background, let first = g.stops.first, let last = g.stops.last {
                HStack {
                    ColorPicker("From", selection: colorBinding({ first.color }) { c in
                        var n = g; n.stops[0].color = c; model.chooseBackground(.linear(n)) }, supportsOpacity: false)
                    ColorPicker("To", selection: colorBinding({ last.color }) { c in
                        var n = g; n.stops[n.stops.count - 1].color = c; model.chooseBackground(.linear(n)) }, supportsOpacity: false)
                }
                .font(.system(size: 12))
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
        return Button { model.chooseBackground(style) } label: {
            Group {
                if style == .transparent {
                    Image(systemName: "nosign").foregroundStyle(.secondary).frame(width: 30, height: 30)
                } else {
                    Image(nsImage: SwatchRenderer.image(id: id, style: style)).resizable().frame(width: 30, height: 30)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Background \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        Section(title: "Layout") {
            SliderRow(title: "Padding", value: s.padding, range: 0...300)
            SliderRow(title: "Inset", value: s.inset, range: 0...200)
            SliderRow(title: "Rounded", value: s.cornerRadius, range: 0...50)
            SliderRow(title: "Shadow", value: Binding(get: { model.settings.shadow.strength }, set: {
                model.settings.shadow.strength = $0; model.settings.shadow.enabled = $0 > 0 }), range: 0...100)
            HStack {
                Text("3D Tilt").font(.system(size: 12))
                Spacer()
                Button("Reset") { model.settings.tilt = .zero }.controlSize(.small)
            }
            SliderRow(title: "Tilt X", value: Binding(get: { model.settings.tilt.x + 15 }, set: { model.settings.tilt = Tilt(uiX: $0, uiY: model.settings.tilt.y + 15) }), range: 0...30)
            SliderRow(title: "Tilt Y", value: Binding(get: { model.settings.tilt.y + 15 }, set: { model.settings.tilt = Tilt(uiX: model.settings.tilt.x + 15, uiY: $0) }), range: 0...30)
        }
    }

    // MARK: Ratio

    private var ratioSection: some View {
        Section(title: "Ratio") {
            let cols = [GridItem(.adaptive(minimum: 62), spacing: 5)]
            LazyVGrid(columns: cols, alignment: .leading, spacing: 5) {
                ForEach(AspectRatioPreset.allBuiltIn, id: \.self) { r in
                    Button { model.settings.aspectRatio = r } label: {
                        Text(shortName(r)).font(.system(size: 10.5)).lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.settings.aspectRatio == r ? .accentColor : nil)
                    .help(r.displayName)
                    .accessibilityLabel("Ratio \(r.displayName)")
                }
            }
            HStack {
                TextField("Custom 4:3 or 1200x630", text: $ui.customRatio).textFieldStyle(.roundedBorder).font(.system(size: 11))
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
        Section(title: "Window frame") {
            Picker("Style", selection: s.windowFrame.style) {
                Text("None").tag(WindowFrameKind.none)
                Text("macOS").tag(WindowFrameKind.macOS)
                Text("Browser").tag(WindowFrameKind.browser)
            }.pickerStyle(.segmented).labelsHidden()
            if model.settings.windowFrame.style != .none {
                Toggle("Dark", isOn: s.windowFrame.dark).toggleStyle(.checkbox)
                TextField("Title", text: s.windowFrame.title).textFieldStyle(.roundedBorder)
            }
            Toggle("Outline border", isOn: s.border.enabled).toggleStyle(.checkbox)
        }
    }

    private var transformSection: some View {
        Section(title: "Transform") {
            HStack(spacing: 8) {
                Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                Button { model.settings.flipHorizontal.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip horizontally")
                Button { model.settings.flipVertical.toggle() } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }.help("Flip vertically")
                Spacer()
            }
            if !model.isEditable, !model.isDesigningPreset {
                Text("Annotations are paused while rotated, flipped or tilted.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Redact

    private var redactSection: some View {
        Section(title: "Auto-redact") {
            let cats = SensitiveCategory.allCases
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                ForEach(cats, id: \.self) { c in
                    Toggle(c.displayName, isOn: Binding(
                        get: { model.redactOptions.categories.contains(c) },
                        set: { on in
                            if on { model.redactOptions.categories.insert(c) } else { model.redactOptions.categories.remove(c) }
                            model.preferences.autoRedactOptions = model.redactOptions
                        })).toggleStyle(.checkbox).font(.system(size: 11))
                }
            }
            TextField("Custom words (comma separated)", text: Binding(
                get: { model.redactOptions.customWords.joined(separator: ", ") },
                set: { v in
                    model.redactOptions.customWords = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    model.preferences.autoRedactOptions = model.redactOptions
                })).textFieldStyle(.roundedBorder).font(.system(size: 11))
            Text("Auto-redact always uses solid fill. Review the image before sharing; detection can miss information.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                ColorPicker("Colour", selection: colorBinding({ model.redactColor }) { model.setRedactColor($0) }, supportsOpacity: false)
                    .font(.system(size: 12))
                Spacer()
            }
            Toggle("Auto-redact new screenshots", isOn: Binding(
                get: { model.preferences.autoRedact }, set: { model.preferences.autoRedact = $0 }))
                .toggleStyle(.switch).controlSize(.small)
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
        Section(title: "Text in image") {
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
                                Text(line.text).font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Copy this line")
                        }
                    }
                }.font(.system(size: 12))
            }
        }
    }

    // MARK: Watermark

    private var watermarkSection: some View {
        Section(title: "Watermark") {
            Toggle("Show watermark", isOn: s.watermark.enabled).toggleStyle(.switch).controlSize(.small)
            if model.settings.watermark.enabled {
                TextField("Text", text: s.watermark.text).textFieldStyle(.roundedBorder)
                Menu("Templates") {
                    ForEach(["Screenshot by Glint", "Made with Glint", "© \(Calendar.current.component(.year, from: Date()))", "@yourhandle"], id: \.self) { t in
                        Button(t) { model.settings.watermark.text = t; model.settings.watermark.kind = .text }
                    }
                    Divider()
                    Button("Image…") { chooseWatermarkImage() }
                }
                Picker("Position", selection: s.watermark.position) {
                    ForEach(WatermarkPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                SliderRow(title: "Opacity", value: Binding(get: { model.settings.watermark.opacity * 100 }, set: { model.settings.watermark.opacity = $0 / 100 }), range: 10...100)
                SliderRow(title: "Size", value: s.watermark.size, range: 8...64)
                ColorPicker("Colour", selection: colorBinding({ model.settings.watermark.color }) { model.settings.watermark.color = $0 }, supportsOpacity: false)
                    .font(.system(size: 12))
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
