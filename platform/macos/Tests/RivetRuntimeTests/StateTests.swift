import Foundation
import Testing
@testable import RivetRuntime

@Test func decodesStateChangeEvent() {
    let value = RivetValue.list([.string("counter"), .int64(42)])
    let change = RivetClient.stateChange(eventName: "$state", value: value)
    #expect(change == RivetStateChange(name: "counter", value: .int64(42)))
}

@Test func ignoresNonStateEvents() {
    let value = RivetValue.list([.string("counter"), .int64(42)])
    #expect(RivetClient.stateChange(eventName: "progress", value: value) == nil)
    #expect(RivetClient.stateChange(eventName: "$state", value: .int64(42)) == nil)
}
