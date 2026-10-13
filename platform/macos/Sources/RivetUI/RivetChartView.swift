import SwiftUI

/// Rolling-time-series chart view backed by ``RivetChartModel``.
///
/// The view owns presentation only: grid, polylines, threshold lines,
/// event markers, and a hover cursor with a per-series readout. Data
/// arrives through the model (chart batches or a windowed pull), so the
/// same view serves live capture, simulator, and replay sources.
public struct RivetChartView: View {

    @ObservedObject var model: RivetChartModel
    var foreground: Color

    @State private var hoverPoint: CGPoint?

    public init(model: RivetChartModel) {
        self.model = model
        self.foreground = .primary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            legend
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilityTitle))
            .accessibilityValue(Text(accessibilitySummary))
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverPoint = point
                case .ended: hoverPoint = nil
                }
            }
            #endif
        }
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(model.specs) { spec in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: spec.color))
                        .frame(width: 10, height: 10)
                    Text(legendText(spec))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if !model.title.isEmpty {
                Text(model.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func legendText(_ spec: RivetChartModel.SeriesSpec) -> String {
        guard let model = model.seriesData[spec.id],
              let latest = model.samples.last else {
            return spec.label
        }
        return "\(spec.label) \(Self.format(latest.value, unit: spec.unit))"
    }

    // MARK: Drawing

    private struct Plot {
        var left: Double
        var top: Double
        var width: Double
        var height: Double
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plot = Plot(left: 68, top: 8, width: Double(size.width) - 68 - 18,
                        height: Double(size.height) - 8 - 30)
        guard plot.width > 0, plot.height > 0 else { return }

        let unit = model.specs.first?.unit ?? ""
        let newest = model.seriesData.values.compactMap(\.newestTs).max() ?? 0
        let tLeft = newest - model.spanNs

        var (vMin, vMax) = visibleValueRange()
        if vMin == vMax {
            vMin -= 1
            vMax += 1
        }

        func x(_ t: Int64) -> Double {
            plot.left + Double(t - tLeft) / Double(max(model.spanNs, 1)) * plot.width
        }
        func y(_ v: Int64) -> Double {
            plot.top + (1.0 - Double(v - vMin) / Double(max(vMax - vMin, 1))) * plot.height
        }

        let gridColor = foreground.opacity(0.18)
        let dimColor = foreground.opacity(0.6)

        // Value grid with labels.
        let vStep = Self.niceStep(Double(vMax - vMin) / 2.618)
        var v = (Double(vMin) / vStep).rounded(.up) * vStep
        while v <= Double(vMax) + vStep * 0.001 {
            let yy = y(Int64(v))
            if yy >= plot.top, yy <= plot.top + plot.height {
                var path = Path()
                path.move(to: CGPoint(x: plot.left, y: yy))
                path.addLine(to: CGPoint(x: plot.left + plot.width, y: yy))
                context.stroke(path, with: .color(gridColor), lineWidth: 1)
                context.draw(
                    Text(Self.format(Int64(v), unit: unit))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary),
                    at: CGPoint(x: plot.left - 6, y: yy),
                    anchor: .trailing
                )
            }
            v += vStep
        }

        // Time grid labeled as negative offsets from "now".
        let tStep = Self.niceStep(Double(model.spanNs) / 2.618)
        var t = (Double(tLeft) / tStep).rounded(.up) * tStep
        while t <= Double(newest) + tStep * 0.001 {
            let xx = x(Int64(t))
            var path = Path()
            path.move(to: CGPoint(x: xx, y: plot.top))
            path.addLine(to: CGPoint(x: xx, y: plot.top + plot.height))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
            // Round to the grid step so labels stay anchored (-20s, -10s)
            // instead of drifting with the sample clock.
            let age = Int64(((Double(newest) - t) / tStep).rounded() * tStep)
            let label = age == 0 ? "now" : "-" + Self.formatDuration(age)
            context.draw(
                Text(label)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(.secondary),
                at: CGPoint(x: xx + 3, y: plot.top + plot.height + 8),
                anchor: .leading
            )
            t += tStep
        }

        context.clip(to: Path(CGRect(x: plot.left, y: plot.top, width: plot.width, height: plot.height)))

        // Thresholds.
        for threshold in model.thresholds {
            let yy = y(threshold.value)
            guard yy >= plot.top, yy <= plot.top + plot.height else { continue }
            var path = Path()
            path.move(to: CGPoint(x: plot.left, y: yy))
            path.addLine(to: CGPoint(x: plot.left + plot.width, y: yy))
            context.stroke(path, with: .color(Color(hex: threshold.color)),
                           style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            if !threshold.label.isEmpty {
                context.draw(
                    Text(threshold.label)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: threshold.color)),
                    at: CGPoint(x: plot.left + plot.width - 4, y: yy - 9),
                    anchor: .trailing
                )
            }
        }

        // Markers.
        for marker in model.markers where marker.tsNs >= tLeft && marker.tsNs <= newest {
            let xx = x(marker.tsNs)
            var path = Path()
            path.move(to: CGPoint(x: xx, y: plot.top))
            path.addLine(to: CGPoint(x: xx, y: plot.top + plot.height))
            context.stroke(path, with: .color(dimColor.opacity(0.8)), lineWidth: 1)
            var tick = Path()
            tick.move(to: CGPoint(x: xx - 4, y: plot.top))
            tick.addLine(to: CGPoint(x: xx + 4, y: plot.top))
            tick.addLine(to: CGPoint(x: xx, y: plot.top + 7))
            tick.closeSubpath()
            context.fill(tick, with: .color(dimColor.opacity(0.9)))
        }

        // Polylines with cursor dots.
        for spec in model.specs {
            guard let series = model.seriesData[spec.id], !series.samples.isEmpty else { continue }
            let start = series.windowStart(spanNs: model.spanNs)
            var polyline = Path()
            var penDown = false
            for index in start..<series.samples.count where series.samples[index].tsNs >= tLeft {
                let point = CGPoint(x: x(series.samples[index].tsNs), y: y(series.samples[index].value))
                if !penDown {
                    polyline.move(to: point)
                    penDown = true
                } else {
                    polyline.addLine(to: point)
                }
            }
            if penDown {
                context.stroke(polyline, with: .color(Color(hex: spec.color)),
                               style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }

            if let hover = hoverPoint {
                let cursorT = tLeft + Int64((hover.x - plot.left) / plot.width * Double(model.spanNs))
                let visible = series.samples[start...]
                guard let pick = visible.min(by: {
                    abs($0.tsNs - cursorT) < abs($1.tsNs - cursorT)
                }) else { continue }
                let dot = CGRect(x: x(pick.tsNs) - 3.5, y: y(pick.value) - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(Color(hex: spec.color)))
            }
        }

        if let hover = hoverPoint, hover.x >= plot.left, hover.x <= plot.left + plot.width {
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: hover.x, y: plot.top))
            crosshair.addLine(to: CGPoint(x: hover.x, y: plot.top + plot.height))
            context.stroke(crosshair, with: .color(dimColor.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func visibleValueRange() -> (Int64, Int64) {
        if !model.autoScale {
            return (model.yMin, model.yMax)
        }
        var vMin: Int64 = 0
        var vMax: Int64 = 0
        var have = false
        for spec in model.specs {
            guard let series = model.seriesData[spec.id] else { continue }
            let start = series.windowStart(spanNs: model.spanNs)
            for index in start..<series.samples.count {
                let value = series.samples[index].value
                if !have {
                    vMin = value
                    vMax = value
                    have = true
                } else {
                    vMin = min(vMin, value)
                    vMax = max(vMax, value)
                }
            }
        }
        if !have {
            return (-1, 1)
        }
        return (vMin, vMax)
    }

    // MARK: Accessibility

    private var accessibilityTitle: String {
        model.title.isEmpty ? "rivet chart" : model.title
    }

    private var accessibilitySummary: String {
        model.specs.compactMap { spec -> String? in
            guard let series = model.seriesData[spec.id],
                  let latest = series.samples.last else { return nil }
            return "\(spec.label) latest \(Self.format(latest.value, unit: spec.unit))"
        }
        .joined(separator: ", ")
    }

    // MARK: Formatting

    static func format(_ value: Int64, unit: String) -> String {
        let magnitude = abs(Double(value))
        let scaled: String
        switch magnitude {
        case 1e9...: scaled = String(format: "%.2fG", Double(value) / 1e9)
        case 1e6...: scaled = String(format: "%.2fM", Double(value) / 1e6)
        case 1e3...: scaled = String(format: "%.2fk", Double(value) / 1e3)
        case 1..<Double.greatestFiniteMagnitude: scaled = "\(value)"
        case 0: scaled = "0"
        default: scaled = String(format: "%.0fn", Double(value))
        }
        return unit.isEmpty ? scaled : scaled + unit
    }

    static func formatDuration(_ ns: Int64) -> String {
        let magnitude = abs(Double(ns))
        if magnitude >= 1e9 {
            return String(format: "%.2fs", Double(ns) / 1e9)
        } else if magnitude >= 1e6 {
            return String(format: "%.1fms", Double(ns) / 1e6)
        } else if magnitude >= 1e3 {
            return String(format: "%.0fµs", Double(ns) / 1e3)
        }
        return "\(ns)ns"
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0 else { return 1 }
        let exponent = Foundation.log10(raw).rounded(.down)
        let fraction = raw / pow(10, exponent)
        let nice: Double
        switch fraction {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...5: nice = 5
        default: nice = 10
        }
        return nice * pow(10, exponent)
    }
}

extension Color {
    /// CSS-style hex color ("#3584e4" or "#ccc"); falls back to secondary
    /// label color so a bad spec degrades instead of crashing the render.
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        var value: UInt64 = 0
        guard Scanner(string: text).scanHexInt64(&value), text.count == 6 || text.count == 8 else {
            self = .secondary
            return
        }
        if text.count == 6 {
            self.init(.sRGB,
                      red: Double((value >> 16) & 0xff) / 255,
                      green: Double((value >> 8) & 0xff) / 255,
                      blue: Double(value & 0xff) / 255,
                      opacity: 1)
        } else {
            self.init(.sRGB,
                      red: Double((value >> 24) & 0xff) / 255,
                      green: Double((value >> 16) & 0xff) / 255,
                      blue: Double((value >> 8) & 0xff) / 255,
                      opacity: Double(value & 0xff) / 255)
        }
    }
}
