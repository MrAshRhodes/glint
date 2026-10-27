import AppKit
import SwiftUI

// Shared Liquid Glass design system for Glint's chrome.
//
// On macOS 26+ (when built with a Swift 6.2+ / macOS 26 SDK toolchain) these helpers use the
// system Liquid Glass material. Older systems and toolchains fall back to the standard
// materials, so the hierarchy (floating functional layer over the content layer) is the same.
// Follow the HIG: use glass only for the functional layer (toolbars, inspector, floating
// action bars), never for content, and never stack glass on glass.

/// Design tokens shared by every Glint surface.
public enum GlintDesign {
    /// Gap between a floating glass panel and the window edge.
    public static let floatingInset: CGFloat = 10
    /// Corner radius of large floating panels (inspector, quick access).
    public static let panelCornerRadius: CGFloat = 18
    /// Corner radius of grouped cards inside a panel; concentric with `panelCornerRadius` at `cardInset`.
    public static let cardCornerRadius: CGFloat = 12
    /// Inset of cards inside a panel so their corners stay concentric with the panel's.
    public static let cardInset: CGFloat = 6
    /// Corner radius of small controls such as swatches and tiles.
    public static let controlCornerRadius: CGFloat = 8
    /// Height of floating toolbars / action bars.
    public static let barHeight: CGFloat = 44
    /// Standard spacing between rows inside a card.
    public static let rowSpacing: CGFloat = 10

    /// Fill for grouped cards that sit on a glass panel (content-layer grouping, not glass).
    public static var cardFill: Color { Color.primary.opacity(0.045) }
    /// Hairline used to separate cards and outline fallback materials.
    public static var hairline: Color { Color.primary.opacity(0.08) }

    /// Whether the running system renders real Liquid Glass.
    public static var supportsLiquidGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

// MARK: - SwiftUI

public extension View {
    /// Applies Liquid Glass (or a material fallback) behind the view, clipped to `shape`.
    /// - Parameters:
    ///   - tint: optional tint, reserved for the primary or selected element.
    ///   - interactive: lets the glass react to pointer/press (macOS 26+).
    @ViewBuilder
    func glintGlass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.modifier(GlassFallback(shape: shape, tint: tint))
        }
        #else
        self.modifier(GlassFallback(shape: shape, tint: tint))
        #endif
    }

    /// Capsule-shaped glass, the default for floating toolbars and action bars.
    func glintGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        glintGlass(in: Capsule(style: .continuous), tint: tint, interactive: interactive)
    }

    /// Rounded-rectangle glass for floating panels such as the inspector.
    func glintGlassPanel(cornerRadius: CGFloat = GlintDesign.panelCornerRadius) -> some View {
        glintGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Grouped card used inside a glass panel (content-layer grouping, never glass on glass).
    func glintCard(cornerRadius: CGFloat = GlintDesign.cardCornerRadius) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(GlintDesign.cardFill))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(GlintDesign.hairline, lineWidth: 0.5))
    }

    /// Glass button style on macOS 26+, bordered elsewhere.
    @ViewBuilder
    func glintGlassButtonStyle(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
        #else
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        #endif
    }
}

private struct GlassFallback<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint.opacity(0.22)) }
                }
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .overlay(shape.inset(by: 0.5).strokeBorder(GlintDesign.hairline, lineWidth: 0.5))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

/// Groups nearby glass shapes so they blend and morph together (macOS 26+); a plain stack elsewhere.
public struct GlintGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - AppKit

/// AppKit host for a floating glass surface: `NSGlassEffectView` on macOS 26+, else `NSVisualEffectView`.
/// Put the surface's content in `contentView`.
@MainActor
public final class GlintGlassView: NSView {
    private let effect: NSView
    private let host = NSView()

    public var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let contentView else { return }
            contentView.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: host.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
    }

    public init(cornerRadius: CGFloat = GlintDesign.panelCornerRadius, material: NSVisualEffectView.Material = .hudWindow) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = host
            effect = glass
        } else {
            effect = Self.fallback(cornerRadius: cornerRadius, material: material, host: host)
        }
        #else
        effect = Self.fallback(cornerRadius: cornerRadius, material: material, host: host)
        #endif
        super.init(frame: .zero)
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func fallback(cornerRadius: CGFloat, material: NSVisualEffectView.Material, host: NSView) -> NSView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            host.topAnchor.constraint(equalTo: v.topAnchor),
            host.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }
}
