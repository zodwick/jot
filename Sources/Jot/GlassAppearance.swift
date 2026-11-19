import AppKit
import QuartzCore

/// Liquid Glass background + a legibility scrim whose opacity is the "density" slider.
///
/// Apple's HIG keeps Liquid Glass for floating, non-content layers. Jot's whole
/// window *is* a small floating panel over other apps, so glass fits, but the
/// text needs help: we use the adaptive `.regular` variant and lay a tinted scrim
/// under the text (Apple's suggested dimming approach), and go fully opaque when
/// Reduce Transparency is on.
enum GlassAppearance {
    /// How far "Float on Top" nudges the slider towards Clear.
    static let floatingShift = 0.12

    /// The density actually used for the scrim.
    /// While floating over other apps the window gets a bit clearer, so you can
    /// see what's underneath: the slider moves 0.12 towards Clear, but never by
    /// more than half its value (low settings don't collapse to fully clear, and
    /// 0 stays 0). Continuous and monotonic, so dragging the slider never jumps.
    static func effectiveDensity(_ density: Double, floating: Bool) -> Double {
        let d = min(max(density, 0), 1)
        guard floating else { return d }
        return max(d - floatingShift, d * 0.5)
    }

    static func apply(glass: NSGlassEffectView, scrim: ScrimView, density: Double, floating: Bool, animated: Bool) {
        let workspace = NSWorkspace.shared
        let reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        // The glass variant follows the user's own slider position, not the
        // floating adjustment, so floating never flips it to the non-adaptive
        // `.clear` variant. Clear glass only at the very bottom of the slider.
        glass.style = density < 0.04 && !reduceTransparency ? .clear : .regular
        let target = reduceTransparency ? 1 : CGFloat(effectiveDensity(density, floating: floating)) * 0.9
        scrim.setOpacity(target, animated: animated && !workspace.accessibilityDisplayShouldReduceMotion)
    }
}

/// Window-background-coloured layer that re-resolves its colour on light/dark changes.
final class ScrimView: NSView {
    private(set) var opacity: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func setOpacity(_ value: CGFloat, animated: Bool) {
        guard value != opacity else { return }
        opacity = value
        guard animated, let layer else { needsDisplay = true; return }
        let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        let to = resolvedColor()
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = 0.25
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "fade")
        layer.backgroundColor = to
    }

    override func updateLayer() {
        layer?.backgroundColor = resolvedColor()
    }

    private func resolvedColor() -> CGColor {
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
        }
        return color
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
