import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

/// SIGTERM must route through the same orderly stop as the quit Apple Event.
/// The embedded Racket CS runtime maps SIGTERM to a Racket break, which a GUI
/// host otherwise swallows — process managers and acceptance suites that
/// terminate the packaged app then hang it forever. The C-level handler only
/// writes one byte to a self-pipe (async-signal-safe); the main run loop's
/// dispatch source performs the real NSApplication.terminate, which runs the
/// applicationShouldTerminate hook and the embedded backend's shutdown.
/// Only the main thread writes the descriptor and the signal handler only
/// reads it; `write` is async-signal-safe, which is what the handler needs.
private nonisolated(unsafe) var orderlySignalWriteFD: Int32 = -1

private func handleOrderlyTerminationSignal(_ signal: Int32) {
    var byte: UInt8 = 1
    _ = write(orderlySignalWriteFD, &byte, 1)
}

@MainActor
enum OrderlySignalHandling {
    private static var pipeFDs: (read: Int32, write: Int32)?
    private static var source: DispatchSourceRead?

    /// Installs (or re-asserts) the SIGTERM handling. Call once at launch and
    /// again after the embedded backend starts: the backend's runtime boot
    /// installs its own signal handlers, so the last installation wins.
    static func install() {
        if pipeFDs == nil {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return }
            fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
            pipeFDs = (fds[0], fds[1])
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fds[0], queue: .main)
            source.setEventHandler {
                var byte: UInt8 = 0
                _ = read(pipeFDs?.read ?? -1, &byte, 1)
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            self.source = source
        }
        orderlySignalWriteFD = pipeFDs?.write ?? -1
        signal(SIGTERM, handleOrderlyTerminationSignal)
    }
}

@main
struct RivetHostApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 360)
                .task {
                    OrderlySignalHandling.install()
                    model.start()
                }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
    }
}

/// Every termination path — Cmd-Q, window close, logout, and OS shutdown —
/// passes through applicationShouldTerminate before the process exits, so
/// the embedded backend gets one orderly stop hook. The AppModel registers
/// its backend shutdown once startup succeeds.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static var orderlyShutdown: (() -> Void)?

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit delivers this callback on the main thread, where the
        // registered shutdown closure lives.
        MainActor.assumeIsolated { Self.orderlyShutdown?() }
        return .terminateNow
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting embedded Racket CS…"
    @Published var count: Int64 = 0
    @Published var ready = false

    private var backend: EmbeddedRacketBackend?

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend
            ApplicationDelegate.orderlyShutdown = { [weak backend] in
                backend?.stop()
            }

            Task.detached { [backend] in
                do {
                    try backend.start()
                    // The backend's runtime boot re-installed its own
                    // SIGTERM handling; ours must win afterwards so a
                    // process manager can stop the packaged app orderly.
                    await MainActor.run { OrderlySignalHandling.install() }
                    let api = RivetAPI(client: backend.client)
                    let initialCount = try await api.get_counter()
                    await MainActor.run {
                        self.count = initialCount
                        self.ready = true
                        self.status = "Embedded Racket CS is ready"
                    }
                } catch {
                    await MainActor.run {
                        self.ready = false
                        self.status = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    func increment() {
        guard let backend, ready else { return }
        let next = count + 1

        Task {
            do {
                let api = RivetAPI(client: backend.client)
                count = try await api.set_counter(next)
            } catch {
                status = "State error: \(error)"
            }
        }
    }

}
