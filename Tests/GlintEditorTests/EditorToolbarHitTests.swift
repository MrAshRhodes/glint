import AppKit
import GlintCore
import SwiftUI
import Testing
@testable import GlintEditor

// The transparent titlebar must not push SwiftUI's tool buttons outside their AppKit hit targets (#63).
@Suite("Editor toolbar hit targets")
@MainActor
struct EditorToolbarHitTests {
    private struct Layout {
        let controller: EditorWindowController
        let content: NSView
        let host: NSView
        let buttons: [EditorTool: NSRect]
    }

    private func layout(_ f: EditorFixture) throws -> Layout {
        let app = NSApplication.shared
        // SwiftUI only materializes accessibility nodes when an accessibility client is present.
        let attributes = ["AXEnhancedUserInterface", "AXManualAccessibility"].map(NSAccessibility.Attribute.init(rawValue:))
        let previousValues = attributes.map { app.accessibilityAttributeValue($0) }
        for attribute in attributes {
            app.accessibilitySetValue(true, forAttribute: attribute)
        }
        defer {
            for (attribute, value) in zip(attributes, previousValues) {
                app.accessibilitySetValue(value, forAttribute: attribute)
            }
        }
        let controller = f.controller(services: EditorExportServices())
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        let host = try #require(content.subviews.first { $0 is NSHostingView<ToolStripView> })
        host.layoutSubtreeIfNeeded()
        var found: [EditorTool: NSRect] = [:]
        for node in Self.descendants(of: host) {
            guard node.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
                  let label = node.value(forKey: "accessibilityLabel") as? String,
                  let tool = EditorTool.allCases.first(where: { $0.title == label }),
                  let frame = (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { continue }
            found[tool] = window.convertFromScreen(frame)
        }
        return Layout(controller: controller, content: content, host: host, buttons: found)
    }

    private static func descendants(of root: NSObject) -> [NSObject] {
        let children = (root.value(forKey: "accessibilityChildren") as? [Any]) ?? []
        return children.compactMap { $0 as? NSObject }.flatMap { [$0] + descendants(of: $0) }
    }

    @Test func everyToolIsExposedAsAButton() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let l = try layout(f)
        for tool in EditorTool.allCases {
            let button = try #require(l.buttons[tool], "\(tool.title) is missing from the toolbar's accessibility tree")
            #expect(button.width > 0 && button.height > 0)
        }
    }

    @Test func toolButtonsLieEntirelyInsideTheirHostingView() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let l = try layout(f)
        let hostFrame = l.host.convert(l.host.bounds, to: nil)
        for tool in EditorTool.allCases {
            let button = try #require(l.buttons[tool])
            #expect(hostFrame.insetBy(dx: -0.5, dy: -0.5).contains(button),
                    "\(tool.title) button \(button) extends outside the toolbar view \(hostFrame)")
        }
    }

    @Test func toolButtonsAreCentredOnTheTrafficLights() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let l = try layout(f)
        let rowCentre = l.content.bounds.height - EditorChromeMetrics.toolbarRowHeight / 2
        for tool in EditorTool.allCases {
            let button = try #require(l.buttons[tool])
            #expect(abs(button.midY - rowCentre) <= 1,
                    "\(tool.title) button is centred at \(button.midY), not on the titlebar row at \(rowCentre)")
        }
    }

    @Test func clickingAnywhereOnAToolButtonReachesTheToolbar() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let l = try layout(f)
        let frame = try #require(l.content.superview)
        for tool in EditorTool.allCases {
            let button = try #require(l.buttons[tool])
            let r = button.insetBy(dx: 3, dy: 3)
            for point in [NSPoint(x: r.midX, y: r.midY), NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
                          NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)] {
                let hit = frame.hitTest(frame.convert(point, from: nil))
                #expect(hit?.isDescendant(of: l.host) == true,
                        "a click at \(point) on the \(tool.title) button goes to \(String(describing: hit)) instead of the toolbar")
            }
        }
    }

}
