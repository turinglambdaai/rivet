import Testing
@testable import RivetRuntime

private func expectAlreadyStarted(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected ClientError.alreadyStarted")
    } catch ClientError.alreadyStarted {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

private func expectStopped(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("expected ClientError.stopped")
    } catch ClientError.stopped {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

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

@Test func clientLifecycleReservesStartBeforeHandshake() throws {
    var lifecycle = ClientLifecycleState()

    try lifecycle.beginStart()
    #expect(!lifecycle.isRunning)
    expectAlreadyStarted { try lifecycle.beginStart() }

    try lifecycle.completeStart()
    #expect(lifecycle.isRunning)
    #expect(lifecycle.stop())
    #expect(!lifecycle.isRunning)
    expectAlreadyStarted { try lifecycle.beginStart() }
}

@Test func clientLifecycleFailedStartCannotRestart() throws {
    var lifecycle = ClientLifecycleState()

    try lifecycle.beginStart()
    lifecycle.failStart()

    #expect(!lifecycle.isRunning)
    expectAlreadyStarted { try lifecycle.beginStart() }
}

@Test func clientLifecycleStopDuringStartPreventsResurrection() throws {
    var lifecycle = ClientLifecycleState()

    try lifecycle.beginStart()
    #expect(!lifecycle.stop())

    expectStopped { try lifecycle.completeStart() }
    #expect(!lifecycle.isRunning)
    expectAlreadyStarted { try lifecycle.beginStart() }
}

@Test func clientLifecycleStopBeforeStartIsTerminal() {
    var lifecycle = ClientLifecycleState()

    #expect(!lifecycle.stop())
    expectAlreadyStarted { try lifecycle.beginStart() }
}
