import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
                .task { model.start() }
                .onOpenURL { url in activationRouter.handle([url]) }
        }
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
    }

    @Published var status = "Starting embedded Racket CS…"
    @Published var tasks: [RivetTypes.BoardTask] = []
    @Published var selectedID: Int64?
    @Published var ready = false
    @Published var generating = false

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

            Task.detached { [backend, relay] in
                do {
                    try backend.start { name, value in
                        guard let event = try? RivetEvent.decode(name: name, value: value) else {
                            return
                        }
                        Task { @MainActor in relay.receive(event) }
                    }
                    let api = RivetAPI(client: backend.client)
                    async let loadedTasks = api.list_tasks()
                    async let selected = api.getSelected_task_id()
                    let (items, selectedID) = try await (loadedTasks, selected)
                    await relay.ready(tasks: items, selectedID: selectedID)
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
                self.status = "Generated 1,000 tasks"
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
        }
    }

}
