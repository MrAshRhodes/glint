import AppKit
import Testing
@testable import GlintCore
@testable import GlintEditor

private func toolKey(_ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

/// Everything a tool press can change, so the click and keyboard paths can be compared as a whole.
private struct ToolState: Equatable {
    let tool: EditorTool
    let shapeVariant: ShapeVariant
    let arrowIsLine: Bool
    let textSize: TextSizeVariant
    let fontSize: Double
    let magnifierShape: MagnifierShape
    let selection: Set<UUID>
    let variant: String?

    @MainActor init(_ model: EditorModel) {
        tool = model.tool
        shapeVariant = model.shapeVariant
        arrowIsLine = model.arrowIsLine
        textSize = model.textSize
        fontSize = model.defaultStyle.fontSize
        magnifierShape = model.magnifierShape
        selection = model.selection
        variant = model.variantDescription()
    }
}

@Suite("Tool shortcuts and toolbar")
@MainActor
struct ToolShortcutTests {
    enum Path: Sendable { case click, key }

    /// Chooses `tool` the way a toolbar click or its shortcut key does.
    @discardableResult
    private func press(_ tool: EditorTool, on controller: EditorWindowController, via path: Path) -> Bool {
        switch path {
        case .click:
            controller.actions.selectTool(tool)
            return true
        case .key:
            return controller.handleShortcut(toolKey(tool.keyHint.lowercased()))
        }
    }

    @Test func keyHintsAreUniqueSingleCharacters() {
        for tool in EditorTool.allCases { #expect(tool.keyHint.count == 1, "\(tool)") }
        let keys = Set(EditorTool.allCases.map { $0.keyHint.lowercased() })
        #expect(keys.count == EditorTool.allCases.count)
    }

    @Test func shortcutKeyRoundTripsEveryKeyHint() {
        for tool in EditorTool.allCases {
            #expect(EditorTool(shortcutKey: tool.keyHint) == tool)
            #expect(EditorTool(shortcutKey: tool.keyHint.lowercased()) == tool)
            #expect(EditorTool(shortcutKey: tool.keyHint.uppercased()) == tool)
        }
        for key in ["", "x", "a", "5", "0", " ", "[", "vv", "12"] { #expect(EditorTool(shortcutKey: key) == nil, "\(key)") }
    }

    @Test(arguments: EditorTool.allCases)
    func unmodifiedShortcutSelectsTool(_ tool: EditorTool) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        let model = controller.model
        model.tool = tool == .select ? .pen : .select

        #expect(controller.handleShortcut(toolKey(tool.keyHint.lowercased())))
        #expect(model.tool == tool)
        model.tool = tool == .select ? .pen : .select
        // Caps Lock isn't a modifier the shortcuts look at, so an upper-case key still selects the tool.
        #expect(controller.handleShortcut(toolKey(tool.keyHint.uppercased())))
        #expect(model.tool == tool)
    }

    @Test(arguments: EditorTool.allCases)
    func modifiedToolKeysAreNotToolShortcuts(_ tool: EditorTool) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        let model = controller.model
        let start: EditorTool = tool == .select ? .pen : .select
        model.tool = start

        #expect(!controller.handleShortcut(toolKey(tool.keyHint.uppercased(), modifiers: .shift)))
        #expect(!controller.handleShortcut(toolKey(tool.keyHint.lowercased(), modifiers: .option)))
        #expect(!controller.handleShortcut(toolKey(tool.keyHint.lowercased(), modifiers: .control)))
        #expect(model.tool == start)
    }

    @Test func unrelatedUnmodifiedKeysAreNotConsumed() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        controller.model.tool = .pen

        for key in ["x", "a", "5", "0", " ", "["] { #expect(!controller.handleShortcut(toolKey(key)), "\(key)") }
        #expect(controller.model.tool == .pen)
    }

    @Test func clicksAndShortcutsStayInSync() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let clicks = f.controller(services: EditorExportServices())
        let keys = f.controller(services: EditorExportServices())
        let mixed = f.controller(services: EditorExportServices())
        defer { for c in [clicks, keys, mixed] { c.window?.close() } }
        let presses: [EditorTool] = [.shape, .shape, .shape, .zoom, .zoom, .zoom, .text, .text, .text, .arrow, .arrow,
                                     .arrow, .shape, .select, .redact, .redact, .counter, .pen, .highlighter, .zoom, .shape]

        for (i, tool) in presses.enumerated() {
            #expect(press(tool, on: clicks, via: .click))
            #expect(press(tool, on: keys, via: .key))
            #expect(press(tool, on: mixed, via: i.isMultiple(of: 2) ? .click : .key))
            let expected = ToolState(clicks.model)
            #expect(expected.tool == tool, "press \(i)")
            #expect(ToolState(keys.model) == expected, "press \(i): \(tool)")
            #expect(ToolState(mixed.model) == expected, "press \(i): \(tool)")
        }
    }

    @Test func alternatingClicksAndKeysCycleShapes() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        let model = controller.model

        press(.shape, on: controller, via: .click)
        #expect(model.tool == .shape && model.shapeVariant == .rectangle)
        var expected = ShapeVariant.rectangle
        for i in 0..<(2 * ShapeVariant.allCases.count) {
            #expect(press(.shape, on: controller, via: i.isMultiple(of: 2) ? .key : .click))
            expected = expected.next
            #expect(model.tool == .shape && model.shapeVariant == expected, "press \(i)")
        }
    }

    @Test func alternatingClicksAndKeysToggleZoomShape() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        let model = controller.model

        press(.zoom, on: controller, via: .key)
        #expect(model.tool == .zoom && model.magnifierShape == .circle)
        press(.zoom, on: controller, via: .click)
        #expect(model.magnifierShape == .rectangle)
        press(.zoom, on: controller, via: .key)
        #expect(model.magnifierShape == .circle)
        press(.select, on: controller, via: .click)
        press(.zoom, on: controller, via: .key)
        #expect(model.tool == .zoom && model.magnifierShape == .circle)
    }

    @Test(arguments: [Path.click, .key])
    func choosingAToolCommitsInlineTextEditing(_ path: Path) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let controller = f.controller(services: EditorExportServices())
        defer { controller.window?.close() }
        let model = controller.model
        let canvas = try #require(controller.window?.contentView?.subviews.lazy.compactMap { $0 as? CanvasView }.first)
        press(.text, on: controller, via: path)
        model.beginInteraction()
        let text = model.makeAnnotation(.text(origin: CGPoint(x: 10, y: 10), string: "", maxWidth: 0))
        model.append(text)
        model.selection = [text.id]
        canvas.beginEditing(id: text.id, isNew: true)
        #expect(model.editingID == text.id)

        #expect(press(.arrow, on: controller, via: path))
        #expect(model.editingID == nil)
        // Committing an empty text annotation discards it.
        #expect(!model.annotations.contains { $0.id == text.id })
        #expect(model.tool == .arrow)
    }
}
