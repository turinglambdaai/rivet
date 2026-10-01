import Foundation
import Testing
@testable import RivetSystem

@Test func notificationAvailabilityRequiresPackagedApplicationIdentity() {
    #expect(
        !RivetNotifications.isAvailable(
            bundleURL: URL(fileURLWithPath: "/tmp/RivetHost"),
            bundleIdentifier: "dev.rivet.example"
        )
    )
    #expect(
        !RivetNotifications.isAvailable(
            bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
            bundleIdentifier: nil
        )
    )
    #expect(
        RivetNotifications.isAvailable(
            bundleURL: URL(fileURLWithPath: "/Applications/Example.APP"),
            bundleIdentifier: "dev.rivet.example"
        )
    )
}

@Test func nonApplicationHostDoesNotEnterUserNotifications() async throws {
    // SwiftPM's test process is not an application bundle. This exercises the
    // same safe path used by `.rivet/stage/RivetHost` during development.
    guard !RivetNotifications.isAvailable else { return }

    let authorized = try await RivetNotifications.requestAuthorization()
    #expect(!authorized)

    do {
        try await RivetNotifications.show(title: "Rivet", body: "Safe staging test")
        Issue.record("expected notificationsUnavailable")
    } catch RivetSystemError.notificationsUnavailable {
        // Expected: no call to UNUserNotificationCenter.current() was made.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
