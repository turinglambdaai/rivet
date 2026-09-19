import SwiftUI
import RivetEmbedding
import RivetRuntime

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 360)
                .task { model.start() }
        }
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
            let config = try Self.runtimeConfiguration()
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend] in
                do {
                    try backend.start()
                    await MainActor.run {
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
        let current = count

        Task {
            do {
                let api = RivetAPI(client: backend.client)
                count = try await api.increment(value: current)
            } catch {
                status = "RPC error: \(error)"
            }
        }
    }

    private static func runtimeConfiguration() throws -> EmbeddedRacketConfiguration {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        // Packaged apps keep Racket data in Contents/Resources. `raco rivet
        // dev` runs the staged executable directly, where runtime/res live next
        // to the executable. Pick the first complete layout so both paths use
        // exactly the same host binary.
        let roots = [
            Bundle.main.resourceURL,
            executable.deletingLastPathComponent()
        ].compactMap { $0 }

        for root in roots {
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let core = root.appendingPathComponent("res/core.zo")
            let required = [
                runtime.appendingPathComponent("petite.boot"),
                runtime.appendingPathComponent("scheme.boot"),
                runtime.appendingPathComponent("racket.boot"),
                core
            ]
            if required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return EmbeddedRacketConfiguration(
                    executable: executable,
                    petiteBoot: required[0],
                    schemeBoot: required[1],
                    racketBoot: required[2],
                    core: core,
                    moduleName: RivetGeneratedConfig.moduleName,
                    entryName: RivetGeneratedConfig.entryName
                )
            }
        }

        throw HostError.missingRuntimeLayout(
            roots.map(\.path).joined(separator: ", ")
        )
    }
}

enum HostError: Error, CustomStringConvertible {
    case missingRuntimeLayout(String)

    var description: String {
        switch self {
        case .missingRuntimeLayout(let roots):
            return "missing Rivet runtime/res layout under: \(roots)"
        }
    }
}
