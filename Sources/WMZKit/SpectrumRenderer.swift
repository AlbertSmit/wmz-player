import AppKit
import CoreGraphics
import Foundation

/// One frame of magnitudes for the visualiser, low frequency first.
public struct SpectrumFrame {
    /// Values are expected in `0...1`. Non-finite values are treated as zero.
    public var bands: [Float]

    public init(bands: [Float]) {
        self.bands = bands
    }
}

/// Look of the spectrum. All sizes are in the context's coordinate space.
public struct SpectrumStyle {
    public var barColor: CGColor
    public var peakColor: CGColor
    public var backgroundColor: CGColor?
    public var barGap: CGFloat
    public var cornerRadius: CGFloat
    /// How much a peak cap falls per draw call once it has stopped holding.
    public var peakFalloff: Double

    /// When enabled, the bar area gives up the bottom `reflectionFraction` of
    /// the rect so the bars can be mirrored there.
    public var showsReflection: Bool
    public var reflectionFraction: CGFloat
    public var reflectionAlpha: CGFloat

    public init(
        barColor: CGColor = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1),
        peakColor: CGColor = CGColor(srgbRed: 1.0, green: 0.86, blue: 0.58, alpha: 1),
        backgroundColor: CGColor? = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        barGap: CGFloat = 2,
        cornerRadius: CGFloat = 1,
        peakFalloff: Double = 0.02,
        showsReflection: Bool = true,
        reflectionFraction: CGFloat = 0.25,
        reflectionAlpha: CGFloat = 0.25
    ) {
        self.barColor = barColor
        self.peakColor = peakColor
        self.backgroundColor = backgroundColor
        self.barGap = barGap
        self.cornerRadius = cornerRadius
        self.peakFalloff = peakFalloff
        self.showsReflection = showsReflection
        self.reflectionFraction = reflectionFraction
        self.reflectionAlpha = reflectionAlpha
    }
}

/// Draws a bar spectrum with falling peak caps and a faint mirrored
/// reflection. Pure drawing: the caller owns the context and the clock.
///
/// The context is expected to be y-down (as used by `SceneRenderer`), so the
/// bars grow upwards from the bottom of `rect`.
public final class SpectrumRenderer {
    public let style: SpectrumStyle

    /// Peak caps stay put for this many draw calls before they start falling.
    private let peakHoldFrames = 8
    private let minimumSide: CGFloat = 8

    private var peaks: [CGFloat] = []
    private var holds: [Int] = []

    public init(style: SpectrumStyle = SpectrumStyle()) {
        self.style = style
    }

    /// Forgets the peak state, e.g. when playback stops or the view changes.
    public func reset() {
        peaks.removeAll(keepingCapacity: false)
        holds.removeAll(keepingCapacity: false)
    }

    public func draw(_ frame: SpectrumFrame, in rect: CGRect, ctx: CGContext) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return }

        let bounds = rect.standardized

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)

        if let background = style.backgroundColor {
            ctx.setFillColor(background)
            ctx.fill(bounds)
        }

        let count = frame.bands.count
        guard count > 0 else {
            reset()
            return
        }
        guard bounds.width >= minimumSide, bounds.height >= minimumSide else { return }

        var values = [CGFloat](repeating: 0, count: count)
        for index in 0..<count {
            let raw = CGFloat(frame.bands[index])
            values[index] = raw.isFinite ? min(max(raw, 0), 1) : 0
        }

        updatePeaks(with: values)
        drawSpectrum(values: values, in: bounds, ctx: ctx)
    }

    // MARK: - Peak state

    private func updatePeaks(with values: [CGFloat]) {
        if peaks.count != values.count || holds.count != values.count {
            peaks = [CGFloat](repeating: 0, count: values.count)
            holds = [Int](repeating: 0, count: values.count)
        }

        let falloff = style.peakFalloff.isFinite
            ? CGFloat(max(0, style.peakFalloff))
            : 0.02

        for index in values.indices {
            let value = values[index]
            if value >= peaks[index] {
                peaks[index] = value
                holds[index] = peakHoldFrames
            } else if holds[index] > 0 {
                holds[index] -= 1
            } else {
                peaks[index] = max(value, peaks[index] - falloff)
            }
            // The cap may never sit below the bar it belongs to.
            peaks[index] = max(peaks[index], value)
        }
    }

    // MARK: - Drawing

    private func drawSpectrum(values: [CGFloat], in bounds: CGRect, ctx: CGContext) {
        let count = values.count
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let baseColor = srgb(style.barColor)
        let tipColor = brightened(baseColor, by: 0.35)
        let peakColor = srgb(style.peakColor)
        let barGradient = CGGradient(
            colorsSpace: space,
            colors: [baseColor, tipColor] as CFArray,
            locations: [0, 1]
        )

        let reflection = style.showsReflection && bounds.height >= 16
        let reflectionFraction = reflection
            ? min(max(style.reflectionFraction.isFinite ? style.reflectionFraction : 0.25, 0), 0.45)
            : 0
        let stripHeight = bounds.height * reflectionFraction
        let meterHeight = bounds.height - stripHeight
        let baseline = bounds.minY + meterHeight

        let requestedGap = style.barGap.isFinite ? max(0, style.barGap) : 0
        let maxGap = count > 1 ? bounds.width / CGFloat(count - 1) * 0.6 : 0
        let gap = min(requestedGap, maxGap)
        let barWidth = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard barWidth > 0, meterHeight > 0 else { return }

        let reflectionGradient: CGGradient? = {
            guard reflection, stripHeight > 0 else { return nil }
            let alpha = style.reflectionAlpha.isFinite ? min(max(style.reflectionAlpha, 0), 1) : 0.25
            let start = baseColor.copy(alpha: baseColor.alpha * alpha) ?? baseColor
            let end = tipColor.copy(alpha: 0) ?? tipColor
            return CGGradient(
                colorsSpace: space,
                colors: [start, end] as CFArray,
                locations: [0, 1]
            )
        }()

        for index in values.indices {
            let x = bounds.minX + CGFloat(index) * (barWidth + gap)
            let value = values[index]
            let barHeight = value * meterHeight

            if barHeight > 0.25 {
                let barRect = CGRect(x: x, y: baseline - barHeight, width: barWidth, height: barHeight)
                ctx.saveGState()
                ctx.addPath(roundedPath(barRect, radius: style.cornerRadius))
                ctx.clip()
                if let barGradient {
                    ctx.drawLinearGradient(
                        barGradient,
                        start: CGPoint(x: barRect.midX, y: baseline),
                        end: CGPoint(x: barRect.midX, y: barRect.minY),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                } else {
                    ctx.setFillColor(baseColor)
                    ctx.fill(barRect)
                }
                ctx.restoreGState()

                if let reflectionGradient, reflection {
                    let reflectedHeight = min(barHeight, stripHeight)
                    let reflected = CGRect(x: x, y: baseline, width: barWidth,
                                           height: reflectedHeight)
                    ctx.saveGState()
                    ctx.addPath(roundedPath(reflected, radius: style.cornerRadius))
                    ctx.clip()
                    ctx.drawLinearGradient(
                        reflectionGradient,
                        start: CGPoint(x: reflected.midX, y: baseline),
                        end: CGPoint(x: reflected.midX, y: baseline + reflectedHeight),
                        options: [.drawsAfterEndLocation]
                    )
                    ctx.restoreGState()
                }
            }
        }

        let capHeight = max(1, min(2.5, meterHeight * 0.04))
        for index in values.indices {
            let peak = peaks[index]
            guard peak > 0.001 else { continue }

            let x = bounds.minX + CGFloat(index) * (barWidth + gap)
            let peakY = baseline - peak * meterHeight
            let capTop = min(max(peakY, bounds.minY), baseline - capHeight)
            let capRect = CGRect(x: x, y: capTop, width: barWidth, height: capHeight)

            ctx.setFillColor(peakColor)
            ctx.addPath(roundedPath(capRect, radius: style.cornerRadius))
            ctx.fillPath()
        }
    }

    // MARK: - Colours

    private func srgb(_ color: CGColor) -> CGColor {
        guard let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return color }
        return converted.cgColor
    }

    private func brightened(_ color: CGColor, by amount: CGFloat) -> CGColor {
        guard let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return color }
        let amount = min(max(amount, 0), 1)
        return NSColor(
            srgbRed: converted.redComponent + (1 - converted.redComponent) * amount,
            green: converted.greenComponent + (1 - converted.greenComponent) * amount,
            blue: converted.blueComponent + (1 - converted.blueComponent) * amount,
            alpha: converted.alphaComponent
        ).cgColor
    }

    private func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = radius.isFinite ? max(0, radius) : 0
        let clamped = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: clamped,
                      cornerHeight: clamped, transform: nil)
    }
}

/// Deterministic spectrum source for previews and demos: a slow sine sweep
/// with a few harmonic bumps, a pulsing low end and a little air on top.
/// Needs no audio capture and returns the same frame for the same time.
public final class SyntheticSpectrum {
    private let bandCount: Int

    public init(bandCount: Int = 32) {
        self.bandCount = max(0, bandCount)
    }

    public func next(at time: TimeInterval) -> SpectrumFrame {
        let time = time.isFinite ? time : 0
        guard bandCount > 0 else { return SpectrumFrame(bands: []) }

        let tau = 2 * Double.pi
        // Travels from the low end to the high end and back over ~20 seconds.
        let sweep = 0.5 - 0.45 * cos(tau * 0.05 * time)
        let envelope = 0.66 + 0.24 * sin(tau * 0.09 * time + 1.1)
        var bands = [Float](repeating: 0, count: bandCount)

        for index in 0..<bandCount {
            let position = bandCount == 1 ? 0.0 : Double(index) / Double(bandCount - 1)
            let main = exp(-pow((position - sweep) / 0.09, 2))
            let echo = 0.50 * exp(-pow((position - (1 - sweep)) / 0.14, 2))
            let harmonic = 0.42 * exp(-pow((position - sweep * 0.5) / 0.075, 2))
            let bass = 0.28 * exp(-position * 4.5) * (0.5 + 0.5 * sin(tau * 0.31 * time + 0.6))
            let air = 0.045 + 0.025 * sin(tau * (position * 6.5 + 0.14 * time))
            let shimmer = 0.05 * sin(tau * (position * 21 + 1.3 * time))
                * sin(tau * (position * 9 - 0.8 * time))

            let value = envelope * (main + echo + harmonic) + bass + air + shimmer
            bands[index] = Float(min(max(value, 0), 1))
        }

        return SpectrumFrame(bands: bands)
    }
}
