import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem
import RivetUI

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
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    OrderlySignalHandling.install()
                    model.start()
                }
                .onOpenURL { url in activationRouter.handle([url]) }
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    static var orderlyShutdown: (() -> Void)?

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    nonisolated func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.orderlyShutdown?() }
        return .terminateNow
    }
}

@MainActor
final class AppModel: ObservableObject {
    @MainActor
    private final class EventRelay {
        weak var model: AppModel?

        init(_ model: AppModel) {
            self.model = model
        }

        func receive(_ event: RivetEvent) {
            model?.receive(event)
        }

        func ready(tasks: [RivetTypes.BoardTask], selectedID: Int64?) {
            guard let model else { return }
            model.tasks = tasks
            model.selectedID = selectedID ?? tasks.first?.id
            model.ready = true
            model.status = "Embedded Racket CS is ready"
        }

        func fail(_ message: String) {
            model?.ready = false
            model?.status = "Backend error: \(message)"
        }

        func configureChart(
            specs: [RivetTypes.TimingSeries],
            thresholds: [RivetTypes.TimingThreshold]
        ) {
            guard let model else { return }
            model.chartModel.setSeries(
                specs.map {
                    RivetChartModel.SeriesSpec(
                        id: $0.id, label: $0.label, color: $0.color, unit: $0.unit
                    )
                }
            )
            model.chartModel.setThresholds(
                thresholds.map {
                    RivetChartModel.Threshold(value: $0.value, label: $0.label, color: $0.color)
                }
            )
            model.chartModel.onGap = { series in
                model.repullChartWindow(series)
            }
        }

        func markStreaming(_ streaming: Bool) {
            model?.streaming = streaming
        }
    }

    @Published var status = "Starting embedded Racket CS…"
    @Published var tasks: [RivetTypes.BoardTask] = []
    @Published var selectedID: Int64?
    @Published var ready = false
    @Published var generating = false
    @Published var streaming = false
    let chartModel = RivetChartModel()

    private var backend: EmbeddedRacketBackend?
    private var generationTask: Task<Void, Never>?

    var selectedTask: RivetTypes.BoardTask? {
        guard let selectedID else { return nil }
        return tasks.first { $0.id == selectedID }
    }

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            let relay = EventRelay(self)
            self.backend = backend
            ApplicationDelegate.orderlyShutdown = { [weak self] in self?.stop() }

            Task.detached { [backend, relay] in
                do {
                    try backend.start { name, value in
                        guard let event = try? RivetEvent.decode(name: name, value: value) else {
                            return
                        }
                        Task { @MainActor in relay.receive(event) }
                    }
                    // The backend's runtime boot re-installed its own
                    // SIGTERM handling; ours must win afterwards so a
                    // process manager can stop the packaged app orderly.
                    await MainActor.run { OrderlySignalHandling.install() }
                    let api = RivetAPI(client: backend.client)
                    async let loadedTasks = api.list_tasks()
                    async let selected = api.get_selected_task_id()
                    async let specs = api.timing_series_specs()
                    async let thresholds = api.timing_decoration()
                    let (items, selectedID, seriesSpecs, seriesThresholds) =
                        try await (loadedTasks, selected, specs, thresholds)
                    await relay.ready(tasks: items, selectedID: selectedID)
                    await relay.configureChart(specs: seriesSpecs, thresholds: seriesThresholds)
                    _ = try? await api.timing_start()
                    await relay.markStreaming(true)
                } catch {
                    await relay.fail(String(describing: error))
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    func createTask() {
        perform("Create failed") { api in
            let created = try await api.create_task(
                title: "New task",
                notes: "Edit the Racket backend to make this workflow your own."
            )
            self.tasks.append(created)
            self.selectedID = created.id
        }
    }

    func advanceSelectedTask() {
        guard let task = selectedTask else { return }
        let next: RivetTypes.TaskStatus = task.status == .backlog ? .active : .done
        perform("Update failed") { api in
            let updated = try await api.update_task(
                id: task.id,
                title: task.title,
                notes: task.notes,
                status: next
            )
            self.replace(updated)
            if next == .done {
                do {
                    if try await RivetNotifications.requestAuthorization() {
                        try await RivetNotifications.show(
                            title: "Task completed",
                            body: updated.title,
                            identifier: "task-\(updated.id)"
                        )
                    }
                } catch {
                    // Notification denial is platform policy, not a failed
                    // Racket mutation. Keep the task update successful.
                }
            }
        }
    }

    func deleteSelectedTask() {
        guard let id = selectedID else { return }
        perform("Delete failed") { api in
            guard try await api.delete_task(id: id) else { return }
            self.tasks.removeAll { $0.id == id }
            self.selectedID = self.tasks.first?.id
        }
    }

    func reloadSamples() {
        perform("Sample reload failed") { api in
            self.tasks = try await api.reload_sample_tasks()
            self.selectedID = self.tasks.first?.id
        }
    }

    func generateDemoTasks() {
        guard let backend, ready, generationTask == nil else { return }
        generating = true
        status = "Preparing the bounded 1,000-row workload…"
        generationTask = Task { [weak self] in
            do {
                let items = try await RivetAPI(client: backend.client)
                    .generate_demo_tasks(count: 1_000)
                guard let self else { return }
                self.tasks = items
                self.selectedID = items.first?.id
                self.status = "Generated \(items.count) tasks"
            } catch is CancellationError {
                self?.status = "Generation cancelled"
            } catch {
                self?.status = "Generation failed: \(error)"
            }
            self?.generating = false
            self?.generationTask = nil
        }
    }

    func cancelGeneration() {
        generationTask?.cancel()
    }

    func toggleStream() {
        guard let backend, ready else { return }
        streaming.toggle()
        Task {
            do {
                if streaming {
                    _ = try await RivetAPI(client: backend.client).timing_start()
                } else {
                    _ = try await RivetAPI(client: backend.client).timing_stop()
                }
            } catch {
                status = "Stream toggle failed: \(error)"
                streaming.toggle()
            }
        }
    }

    func repullChartWindow(_ series: String) {
        guard let backend else { return }
        Task {
            do {
                let window = try await RivetAPI(client: backend.client).timing_window(series_id: series)
                chartModel.replaceSeries(
                    series,
                    window: window.samples.map { RivetChartBatch.Sample(tsNs: $0.ts, value: $0.value) },
                    watermark: UInt64(bitPattern: window.watermark)
                )
            } catch {
                status = "Chart window pull failed: \(error)"
            }
        }
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
        backend?.stop()
        backend = nil
        ready = false
    }

    func persistSelection(_ id: Int64?) {
        guard let id, let backend, ready else { return }
        Task {
            do {
                _ = try await RivetAPI(client: backend.client).select_task(id: id)
            } catch {
                status = "Selection failed: \(error)"
            }
        }
    }

    func label(for status: RivetTypes.TaskStatus) -> String {
        switch status {
        case .backlog: "Backlog"
        case .active: "In progress"
        case .done: "Done"
        }
    }

    func nextActionLabel(for status: RivetTypes.TaskStatus) -> String {
        status == .backlog ? "Start Task" : "Mark Done"
    }

    private func perform(
        _ failurePrefix: String,
        operation: @escaping (RivetAPI) async throws -> Void
    ) {
        guard let backend, ready else { return }
        Task {
            do {
                try await operation(RivetAPI(client: backend.client))
                status = "Saved by the Racket backend"
            } catch {
                status = "\(failurePrefix): \(error)"
            }
        }
    }

    private func replace(_ updated: RivetTypes.BoardTask) {
        if let index = tasks.firstIndex(where: { $0.id == updated.id }) {
            tasks[index] = updated
        }
    }

    private func receive(_ event: RivetEvent) {
        switch event {
        case .operation_progress(let progress):
            status = progress.message
        case .task_saved(let task):
            replace(task)
        case .chart_batch(let envelope):
            chartModel.appendBatch(envelope.batch, series: envelope.series)
        }
    }

}
