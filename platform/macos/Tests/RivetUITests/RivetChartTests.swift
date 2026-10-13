import Foundation
import Testing
@testable import RivetUI

// The golden bytes are the same vectors that pin rivet/chart.rkt and
// runtime/tests/chart_batch_test.cpp; the three decoders must stay
// byte-identical.

@Test func decodeGoldenBatch() throws {
    let golden: [UInt8] = [
        0x31, 0x43, 0x56, 0x52, 0x02, 0x00, 0x00, 0x00,
        0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xf4, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    let batch = try RivetChartBatch.decode(Data(golden))
    #expect(batch.firstIndex == 7)
    #expect(batch.samples == [
        RivetChartBatch.Sample(tsNs: 1, value: -12),
        RivetChartBatch.Sample(tsNs: 2, value: 40),
    ])
}

@Test func encodeRoundTrip() throws {
    var samples: [RivetChartBatch.Sample] = []
    for i in 0..<500 {
        samples.append(RivetChartBatch.Sample(tsNs: Int64(i) * 1000, value: Int64(i % 37) - 18))
    }
    let encoded = RivetChartBatch.encode(samples, firstIndex: 4242)
    let batch = try RivetChartBatch.decode(encoded)
    #expect(batch.firstIndex == 4242)
    #expect(batch.samples == samples)
}

@Test func decodeRejectsMalformed() {
    #expect(throws: RivetChartBatch.DecodeError.self) {
        try RivetChartBatch.decode(Data([0x31]))
    }
    #expect(throws: RivetChartBatch.DecodeError.self) {
        try RivetChartBatch.decode(Data(repeating: 0, count: 32))
    }
    #expect(throws: RivetChartBatch.DecodeError.self) {
        // Header declares two samples; only one follows.
        try RivetChartBatch.decode(Data([
            0x31, 0x43, 0x56, 0x52, 0x02, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))
    }
}

@Test func seriesModelApplyStates() {
    var model = RivetChartSeriesModel()
    #expect(model.apply(RivetChartBatch.Batch(firstIndex: 0, samples: [.init(tsNs: 1, value: 10)])) == .appended)
    #expect(model.watermark == 1)
    #expect(model.apply(RivetChartBatch.Batch(firstIndex: 0, samples: [.init(tsNs: 1, value: 10)])) == .stale)
    #expect(model.apply(RivetChartBatch.Batch(firstIndex: 3, samples: [.init(tsNs: 5, value: 50)])) == .gap)

    let overlap = RivetChartBatch.Batch(firstIndex: 1, samples: [
        .init(tsNs: 2, value: 20), .init(tsNs: 3, value: 30), .init(tsNs: 4, value: 40),
    ])
    #expect(model.apply(overlap) == .appended)
    #expect(model.watermark == 4)
    #expect(model.samples.count == 4)
}

@Test func seriesModelWindowAndTrim() {
    var model = RivetChartSeriesModel(capacity: 4)
    model.apply(RivetChartBatch.Batch(firstIndex: 0, samples: [
        .init(tsNs: 0, value: 0), .init(tsNs: 100, value: 1),
        .init(tsNs: 200, value: 2), .init(tsNs: 10_000, value: 3),
    ]))
    #expect(model.windowStart(spanNs: 500) == 3)
    #expect(model.windowStart(spanNs: 10_000) == 0)

    model.apply(RivetChartBatch.Batch(firstIndex: 4, samples: [
        .init(tsNs: 10_100, value: 4), .init(tsNs: 10_200, value: 5),
    ]))
    #expect(model.samples.count <= 4)
    #expect(model.newestTs == 10_200)

    model.resetFromWindow([.init(tsNs: 100, value: 1)], watermark: 8)
    #expect(model.watermark == 8)
    model.clear()
    #expect(model.samples.isEmpty && model.watermark == 0)
}

@MainActor
@Test func chartModelRoutesBatches() {
    let model = RivetChartModel()
    model.setSeries([
        .init(id: "offset", label: "offset", color: "#3584e4", unit: "ns"),
        .init(id: "delay", label: "delay", color: "#e01b24", unit: "ns"),
    ])

    let first = RivetChartBatch.encode([.init(tsNs: 1, value: -5)], firstIndex: 0)
    #expect(model.appendBatch(first, series: "offset") == .appended)
    #expect(model.appendBatch(first, series: "delay") == .appended)
    #expect(model.appendBatch(first, series: "offset") == .stale)
    #expect(model.appendBatch(first, series: "ghost") == .unknownSeries)
    #expect(model.appendBatch(Data([0x00]), series: "offset") == .malformed)

    var gapReports: [String] = []
    model.onGap = { gapReports.append($0) }
    let gap = RivetChartBatch.encode([.init(tsNs: 9, value: 1)], firstIndex: 3)
    #expect(model.appendBatch(gap, series: "offset") == .gap)
    #expect(gapReports == ["offset"])

    model.replaceSeries("offset", window: [.init(tsNs: 5, value: 5), .init(tsNs: 9, value: 1)],
                        watermark: 4)
    #expect(model.seriesData["offset"]?.samples.count == 2)

    model.clear()
    #expect(model.seriesData["offset"]?.samples.isEmpty == true)
}

@Test func formattingHelpers() {
    #expect(RivetChartView.format(1_500, unit: "ns") == "1.50kns")
    #expect(RivetChartView.format(-12, unit: "ns") == "-12ns")
    #expect(RivetChartView.formatDuration(1500).hasSuffix("µs"))
    #expect(RivetChartView.formatDuration(2_500_000_000) == "2.50s")
}
