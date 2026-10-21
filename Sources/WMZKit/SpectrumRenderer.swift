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

/// The visualisation drawn inside an `<effects>` pane.
///
/// The names echo the visualisations that shipped with Windows Media Player 9
/// and 10, reimagined for one flat pass over the band data.
public enum SpectrumShape: CaseIterable {
    /// Discrete bars with falling peak caps and an optional reflection.
    case bars
    /// Oscilloscope-style smoothed polyline with a soft glow and a fill.
    case wave
    /// Tapered spikes from the centre line, mirrored below it, with bright tips.
    case spikes
    /// Grid of small cells: columns are bands, lit rows are energy.
    case dots
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

    /// Which visualisation to draw. `barGap` spaces the columns of every
    /// shape; peaks and the reflection only apply to `.bars`.
    public var shape: SpectrumShape

    public init(
        barColor: CGColor = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1),
        peakColor: CGColor = CGColor(srgbRed: 1.0, green: 0.86, blue: 0.58, alpha: 1),
        backgroundColor: CGColor? = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        barGap: CGFloat = 2,
        cornerRadius: CGFloat = 1,
        peakFalloff: Double = 0.02,
        showsReflection: Bool = true,
        reflectionFraction: CGFloat = 0.25,
        reflectionAlpha: CGFloat = 0.25,
        shape: SpectrumShape = .bars
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
        self.shape = shape
    }
}

/// Draws a spectrum in one of several shapes: bars with falling peak caps,
/// a glowing oscilloscope wave, centre-mirrored spikes or an energy grid.
/// Pure drawing: the caller owns the context and the clock.
///
/// The context is expected to be y-down (as used by `SceneRenderer`), so the
/// visualisation grows upwards from the bottom of `rect`.
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
        switch style.shape {
        case .bars: drawBars(values: values, in: bounds, ctx: ctx)
        case .wave: drawWave(values: values, in: bounds, ctx: ctx)
        case .spikes: drawSpikes(values: values, in: bounds, ctx: ctx)
        case .dots: drawDots(values: values, in: bounds, ctx: ctx)
        }
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

    private func drawBars(values: [CGFloat], in bounds: CGRect, ctx: CGContext) {
        let count = values.count
        let space = sRGBSpace

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
        guard let layout = columnLayout(count: count, in: bounds) else { return }
        let barWidth = layout.width
        let gap = layout.gap
        guard meterHeight > 0 else { return }

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

    // MARK: - Wave

    private func drawWave(values: [CGFloat], in bounds: CGRect, ctx: CGContext) {
        let baseColor = srgb(style.barColor)
        let lineColor = brightened(baseColor, by: 0.18)

        // Keep the crest off the very edge so the glow has room to breathe.
        let inset = min(bounds.height * 0.1, 8)
        let top = bounds.minY + inset
        let bottom = bounds.maxY - inset
        let span = bottom - top
        guard span > 1 else { return }

        let points = wavePoints(values: values, in: bounds, top: top, bottom: bottom)
        guard points.count > 1, let last = points.last, let first = points.first else { return }

        let line = smoothPath(points, clampY: top...bottom)
        let fill = CGMutablePath()
        fill.addPath(line)
        fill.addLine(to: CGPoint(x: last.x, y: bottom))
        fill.addLine(to: CGPoint(x: first.x, y: bottom))
        fill.closeSubpath()

        if let gradient = CGGradient(
            colorsSpace: sRGBSpace,
            colors: [
                baseColor.copy(alpha: baseColor.alpha * 0.42) ?? baseColor,
                baseColor.copy(alpha: 0.02) ?? baseColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.saveGState()
            ctx.addPath(fill)
            ctx.clip()
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.midX, y: top),
                end: CGPoint(x: bounds.midX, y: bottom),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            ctx.restoreGState()
        }

        let blur = min(10, max(2, bounds.height * 0.055))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur,
                      color: lineColor.copy(alpha: 0.8))
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(line)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func wavePoints(values: [CGFloat], in bounds: CGRect,
                            top: CGFloat, bottom: CGFloat) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let span = bottom - top
        if values.count == 1 {
            let y = bottom - values[0] * span
            return [CGPoint(x: bounds.minX, y: y), CGPoint(x: bounds.maxX, y: y)]
        }
        return values.indices.map { index in
            let x = bounds.minX + bounds.width * CGFloat(index) / CGFloat(values.count - 1)
            return CGPoint(x: x, y: bottom - values[index] * span)
        }
    }

    /// Catmull-Rom through the points, expressed as cubic Beziers. Control
    /// points are clamped vertically so a lone peak cannot loop outside the pane.
    private func smoothPath(_ points: [CGPoint], clampY: ClosedRange<CGFloat>) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        func clamp(_ y: CGFloat) -> CGFloat {
            min(max(y, clampY.lowerBound), clampY.upperBound)
        }

        for index in 0..<(points.count - 1) {
            let previous = points[max(index - 1, 0)]
            let current = points[index]
            let next = points[index + 1]
            let following = points[min(index + 2, points.count - 1)]
            let control1 = CGPoint(x: current.x + (next.x - previous.x) / 6,
                                   y: current.y + (next.y - previous.y) / 6)
            let control2 = CGPoint(x: next.x - (following.x - current.x) / 6,
                                   y: next.y - (following.y - current.y) / 6)
            path.addCurve(
                to: next,
                control1: CGPoint(x: control1.x, y: clamp(control1.y)),
                control2: CGPoint(x: control2.x, y: clamp(control2.y))
            )
        }
        return path
    }

    // MARK: - Spikes

    private func drawSpikes(values: [CGFloat], in bounds: CGRect, ctx: CGContext) {
        guard let layout = columnLayout(count: values.count, in: bounds) else { return }
        let centreY = bounds.midY
        let baseColor = srgb(style.barColor)
        let tipColor = srgb(style.peakColor)
        let tipRadius = max(1, min(2.5, layout.width * 0.2))
        // Leave room for the tip dot so a full band never clips at the top.
        let reach = bounds.height / 2 - tipRadius - 1.5
        guard reach > 0 else { return }

        let spikeGradient = CGGradient(
            colorsSpace: sRGBSpace,
            colors: [baseColor, tipColor] as CFArray,
            locations: [0, 1]
        )
        let mirrorColor = baseColor.copy(alpha: baseColor.alpha * 0.3) ?? baseColor

        for index in values.indices {
            let value = values[index]
            guard value > 0.002 else { continue }

            let columnX = bounds.minX + CGFloat(index) * (layout.width + layout.gap)
            let centerX = columnX + layout.width / 2
            let length = max(1, value * reach)
            let baseHalf = max(0.5, layout.width * 0.42)
            let tipHalf = max(0.35, baseHalf * 0.16)

            // Dimmer mirror below the centre line, so the spike reads as centred.
            ctx.setFillColor(mirrorColor)
            ctx.addPath(spikePath(centerX: centerX, centreY: centreY,
                                  baseHalf: baseHalf, tipHalf: tipHalf,
                                  length: length * 0.7, upwards: false))
            ctx.fillPath()

            let spike = spikePath(centerX: centerX, centreY: centreY,
                                  baseHalf: baseHalf, tipHalf: tipHalf,
                                  length: length, upwards: true)
            ctx.saveGState()
            ctx.addPath(spike)
            ctx.clip()
            if let spikeGradient {
                ctx.drawLinearGradient(
                    spikeGradient,
                    start: CGPoint(x: centerX, y: centreY),
                    end: CGPoint(x: centerX, y: centreY - length),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            } else {
                ctx.setFillColor(baseColor)
                ctx.fill(bounds)
            }
            ctx.restoreGState()

            let tip = CGRect(x: centerX - tipRadius,
                             y: centreY - length - tipRadius,
                             width: tipRadius * 2, height: tipRadius * 2)
            ctx.setFillColor(tipColor)
            ctx.fillEllipse(in: tip)
        }
    }

    private func spikePath(centerX: CGFloat, centreY: CGFloat,
                           baseHalf: CGFloat, tipHalf: CGFloat,
                           length: CGFloat, upwards: Bool) -> CGPath {
        let direction: CGFloat = upwards ? -1 : 1
        let tipY = centreY + direction * length
        let path = CGMutablePath()
        path.move(to: CGPoint(x: centerX - baseHalf, y: centreY))
        path.addLine(to: CGPoint(x: centerX - tipHalf, y: tipY))
        path.addLine(to: CGPoint(x: centerX + tipHalf, y: tipY))
        path.addLine(to: CGPoint(x: centerX + baseHalf, y: centreY))
        path.closeSubpath()
        return path
    }

    // MARK: - Dots

    private func drawDots(values: [CGFloat], in bounds: CGRect, ctx: CGContext) {
        guard let layout = columnLayout(count: values.count, in: bounds) else { return }
        let pitch = layout.width + layout.gap
        guard pitch > 0 else { return }

        // Roughly square cells, with a sane row budget for very tall panes.
        let rowCount = max(2, min(12, Int((bounds.height / pitch).rounded())))
        let rowPitch = bounds.height / CGFloat(rowCount)
        let cellWidth = max(0.5, layout.width * 0.72)
        let cellHeight = max(0.5, rowPitch * 0.68)
        let radius = min(cellWidth, cellHeight) * 0.3

        let dimPath = CGMutablePath()
        let litPath = CGMutablePath()

        for index in values.indices {
            let columnX = bounds.minX + CGFloat(index) * (layout.width + layout.gap)
            let cellX = columnX + (layout.width - cellWidth) / 2
            let litRows = min(rowCount, Int((values[index] * CGFloat(rowCount)).rounded(.up)))

            for row in 0..<rowCount {
                let cellY = bounds.maxY - CGFloat(row + 1) * rowPitch + (rowPitch - cellHeight) / 2
                let cell = CGRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight)
                let path = roundedPath(cell, radius: radius)
                if row < litRows, values[index] > 0.001 {
                    litPath.addPath(path)
                } else {
                    dimPath.addPath(path)
                }
            }
        }

        let baseColor = srgb(style.barColor)
        ctx.setFillColor(baseColor.copy(alpha: min(0.12, baseColor.alpha * 0.12)) ?? baseColor)
        ctx.addPath(dimPath)
        ctx.fillPath()

        guard !litPath.isEmpty else { return }
        ctx.saveGState()
        ctx.addPath(litPath)
        ctx.clip()
        if let gradient = CGGradient(
            colorsSpace: sRGBSpace,
            colors: [srgb(style.peakColor), baseColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: bounds.midX, y: bounds.minY),
                end: CGPoint(x: bounds.midX, y: bounds.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            ctx.setFillColor(baseColor)
            ctx.fill(bounds)
        }
        ctx.restoreGState()
    }

    // MARK: - Layout

    /// Equal columns across the rect with the style's gap, shrunk when the
    /// rect is too narrow for the requested gap.
    private func columnLayout(count: Int, in bounds: CGRect) -> (width: CGFloat, gap: CGFloat)? {
        guard count > 0 else { return nil }
        let requestedGap = style.barGap.isFinite ? max(0, style.barGap) : 0
        let maxGap = count > 1 ? bounds.width / CGFloat(count - 1) * 0.6 : 0
        let gap = min(requestedGap, maxGap)
        let width = (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard width.isFinite, width > 0 else { return nil }
        return (width, gap)
    }

    // MARK: - Colours

    private var sRGBSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

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
