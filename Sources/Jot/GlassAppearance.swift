import AppKit

/// Liquid Glass background + a legibility scrim whose opacity is the "density" slider.
///
/// Apple's HIG keeps Liquid Glass for floating, non-content layers. Jot's whole
/// window *is* a small floating panel over other apps, so glass fits, but the
/// text needs help: we use the adaptive `.regular` variant and lay a tinted scrim
/// under the text (Apple's suggested dimming approach), and go fully opaque when
/// Reduce Transparency is on.
enum GlassAppearance {
    static func apply(glass: NSGlassEffectView, scrim: ScrimView, density: Double) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Clear glass only at the very bottom of the slider; it isn't adaptive.
        glass.style = density < 0.04 && !reduceTransparency ? .clear : .regular
        scrim.opacity = reduceTransparency ? 1 : CGFloat(density) * 0.9
    }
}

/// Window-background-coloured layer that re-resolves its colour on light/dark changes.
final class ScrimView: NSView {
    var opacity: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
