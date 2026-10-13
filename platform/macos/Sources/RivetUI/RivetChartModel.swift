import Combine
import Foundation

/// Host-side accumulator for one chart series, mirroring
/// `rivet::chart::SeriesModel` in the portable C++ runtime.
///
/// The watermark (the next absolute index expected from the backend) lets
/// the owner tell an in-order batch from a stale replay and from a gap
/// caused by ring eviction on the Racket side. A gap is not repaired here;
/// the application re-pulls the window through its typed RPC and calls
/// `resetFromWindow(_:watermark:)`.
public struct RivetChartSeriesModel: Sendable, Equatable {

    public enum ApplyOutcome: Equatable, Sendable {
        case appended
        case stale
        case gap
    }

    private(set) public var samples: [RivetChartBatch.Sample] = []
    private(set) public var watermark: UInt64 = 0
    private var capacity: Int

    public init(capacity: Int = 16_384) {
        self.capacity = max(1, capacity)
    }

    public mutating func apply(_ batch: RivetChartBatch.Batch) -> ApplyOutcome {
        if batch.firstIndex + UInt64(batch.samples.count) <= watermark {
            return .stale
        }
        guard batch.firstIndex <= watermark else { return .gap }
        let skip = Int(watermark - batch.firstIndex)
        for index in skip..<batch.samples.count {
            append(batch.samples[index])
        }
        watermark += UInt64(batch.samples.count - skip)
        return .appended
    }

    public mutating func appendLocal(_ sample: RivetChartBatch.Sample) {
        append(sample)
    }

    public mutating func resetFromWindow(_ window: [RivetChartBatch.Sample], watermark: UInt64) {
        samples = window
        self.watermark = watermark
        trim()
    }

    public mutating func clear() {
        samples.removeAll()
        watermark = 0
    }

    public var newestTs: Int64? {
        samples.last?.tsNs
    }

    /// Index of the first sample not older than `newestTs - spanNs`.
    public func windowStart(spanNs: Int64) -> Int {
        guard let newest = samples.last?.tsNs, spanNs >= 0 else { return 0 }
        let cutoff = newest - spanNs
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].tsNs < cutoff {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private mutating func append(_ sample: RivetChartBatch.Sample) {
        if let last = samples.last, sample.tsNs <= last.tsNs {
            // Malformed input must not corrupt the visible window; drop the
            // batch tail rather than throw from a UI-driven call site.
            return
        }
        samples.append(sample)
        trim()
    }

    private mutating func trim() {
        guard samples.count > capacity else { return }
        let chunk = max(samples.count - capacity, capacity / 4)
        samples.removeFirst(min(chunk, samples.count))
    }
}

/// Presentation spec and observable chart state for `RivetChartView`.
///
/// Mutate only from the main actor (RVT1 event dispatch hops there anyway);
/// the published snapshots keep SwiftUI redraws proportional to batch rate.
@MainActor
public final class RivetChartModel: ObservableObject {

    public struct SeriesSpec: Identifiable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var color: String
        public var unit: String

        public init(id: String, label: String, color: String, unit: String = "") {
            self.id = id
            self.label = label
            self.color = color
            self.unit = unit
        }
    }

    public struct Threshold: Identifiable, Sendable, Equatable {
        public var id: String { label }
        public var value: Int64
        public var label: String
        public var color: String

        public init(value: Int64, label: String, color: String) {
            self.value = value
            self.label = label
            self.color = color
        }
    }

    public struct Marker: Identifiable, Sendable, Equatable {
        public var id: String { "\(tsNs)-\(label)" }
        public var tsNs: Int64
        public var label: String

        public init(tsNs: Int64, label: String) {
            self.tsNs = tsNs
            self.label = label
        }
    }

    @Published public private(set) var specs: [SeriesSpec] = []
    @Published public private(set) var thresholds: [Threshold] = []
    @Published public private(set) var markers: [Marker] = []
    @Published public private(set) var title: String = ""
    @Published public private(set) var spanNs: Int64 = 30_000_000_000
    @Published public private(set) var autoScale = true
    @Published public private(set) var yMin: Int64 = 0
    @Published public private(set) var yMax: Int64 = 0
    @Published public private(set) var seriesData: [String: RivetChartSeriesModel] = [:]

    /// Fired when a batch gap means the owner must re-pull that series.
    public var onGap: (@MainActor (String) -> Void)?

    public init() {}

    public func setSeries(_ specs: [SeriesSpec]) {
        self.specs = specs
        var fresh: [String: RivetChartSeriesModel] = [:]
        for spec in specs where seriesData[spec.id] == nil {
            fresh[spec.id] = RivetChartSeriesModel()
        }
        seriesData = seriesData.filter { entry in specs.contains(where: { $0.id == entry.key }) }
        for (id, model) in fresh {
            seriesData[id] = model
        }
    }

    public func setTitle(_ title: String) {
        self.title = title
    }

    public func setWindow(_ spanNs: Int64) {
        guard spanNs > 0 else { return }
        self.spanNs = spanNs
    }

    public func setYRange(auto: Bool, min: Int64 = 0, max: Int64 = 0) {
        autoScale = auto
        yMin = min
        yMax = max
    }

    public func setThresholds(_ thresholds: [Threshold]) {
        self.thresholds = thresholds
    }

    public func setMarkers(_ markers: [Marker]) {
        self.markers = markers
    }

    public enum BatchOutcome: Equatable, Sendable {
        case appended
        case stale
        case gap
        case unknownSeries
        case malformed
    }

    @discardableResult
    public func appendBatch(_ data: Data, series: String) -> BatchOutcome {
        guard seriesData[series] != nil else { return .unknownSeries }
        let batch: RivetChartBatch.Batch
        do {
            batch = try RivetChartBatch.decode(data)
        } catch {
            return .malformed
        }
        let outcome = seriesData[series]?.apply(batch) ?? .stale
        if outcome == .gap {
            onGap?(series)
        }
        return batchOutcome(from: outcome)
    }

    public func replaceSeries(_ series: String, window: [RivetChartBatch.Sample], watermark: UInt64) {
        guard seriesData[series] != nil else { return }
        seriesData[series]?.resetFromWindow(window, watermark: watermark)
    }

    public func clear() {
        for id in seriesData.keys {
            seriesData[id]?.clear()
        }
    }

    private func batchOutcome(from outcome: RivetChartSeriesModel.ApplyOutcome) -> BatchOutcome {
        switch outcome {
        case .appended: return .appended
        case .stale: return .stale
        case .gap: return .gap
        }
    }
}
