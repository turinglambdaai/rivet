import Testing
@testable import RivetRuntime

@Test func requestIDAllocatorWrapsWithoutZero() {
    var allocator = RequestIDAllocator(nextID: UInt64.max)
    let empty = Set<UInt64>()

    #expect(allocator.allocate(occupiedCount: 0) { empty.contains($0) } == UInt64.max)
    #expect(allocator.allocate(occupiedCount: 0) { empty.contains($0) } == 1)
}

@Test func requestIDAllocatorSkipsPendingCollisions() {
    var allocator = RequestIDAllocator(nextID: UInt64.max)
    let occupied: Set<UInt64> = [UInt64.max, 1, 2]

    #expect(
        allocator.allocate(occupiedCount: occupied.count) { occupied.contains($0) } == 3
    )
}

@Test func requestIDAllocatorNormalizesZeroSeed() {
    var allocator = RequestIDAllocator(nextID: 0)
    #expect(allocator.allocate(occupiedCount: 0) { _ in false } == 1)
}

@Test func cancellationBeforeRegistrationAbortsWithoutSend() {
    let state = RequestCancellationState()

    #expect(state.cancel() == nil)
    #expect(state.register(41))
}

@Test func cancellationBeforeRequestWriteIsDeferredAndSentOnce() {
    let state = RequestCancellationState()

    #expect(!state.register(42))
    #expect(state.cancel() == nil)
    #expect(state.markRequestSent() == 42)
    #expect(state.cancel() == nil)
    #expect(state.markRequestSent() == nil)
}

@Test func cancellationAfterRequestWriteCanSendImmediatelyOnce() {
    let state = RequestCancellationState()

    #expect(!state.register(43))
    #expect(state.markRequestSent() == nil)
    #expect(state.cancel() == 43)
    #expect(state.cancel() == nil)
}
