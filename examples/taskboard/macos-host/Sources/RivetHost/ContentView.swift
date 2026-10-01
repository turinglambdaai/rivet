import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if model.tasks.isEmpty && model.ready {
                    ContentUnavailableView(
                        "No tasks",
                        systemImage: "checklist",
                        description: Text("Create a task or reload the packaged sample data.")
                    )
                } else {
                    List(selection: $model.selectedID) {
                        ForEach(model.tasks, id: \.id) { task in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title)
                                    .font(.headline)
                                Text(model.label(for: task.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(task.id)
                            .accessibilityIdentifier("task-row-\(task.id)")
                        }
                    }
                    .accessibilityIdentifier("task-list")
                }

                HStack {
                    Button("New Task", systemImage: "plus") { model.createTask() }
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityIdentifier("new-task")
                    Button("Samples", systemImage: "arrow.clockwise") {
                        model.reloadSamples()
                    }
                    .accessibilityIdentifier("reload-samples")
                }
                .buttonStyle(.borderless)
                .padding(12)
                .disabled(!model.ready || model.generating)
            }
            .navigationTitle("Rivet Taskboard")
            .frame(minWidth: 280)
        } detail: {
            if let task = model.selectedTask {
                VStack(alignment: .leading, spacing: 18) {
                    Text(task.title)
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("task-title")
                    Text(model.label(for: task.status))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(task.notes)
                        .font(.body)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("task-notes")
                    Spacer()
                    HStack {
                        Button(model.nextActionLabel(for: task.status)) {
                            model.advanceSelectedTask()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("advance-task")
                        Button("Delete", role: .destructive) { model.deleteSelectedTask() }
                            .accessibilityIdentifier("delete-task")
                    }
                    .disabled(model.generating)
                }
                .padding(32)
            } else {
                ContentUnavailableView(
                    "Select a task",
                    systemImage: "sidebar.left",
                    description: Text("Task details are provided by the shared Racket backend.")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Generate 1,000") { model.generateDemoTasks() }
                    .disabled(!model.ready || model.generating)
                    .accessibilityIdentifier("generate-demo")
                if model.generating {
                    Button("Cancel", role: .cancel) { model.cancelGeneration() }
                        .accessibilityIdentifier("cancel-generation")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.generating { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.callout)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("application-status")
        }
        .onChange(of: model.selectedID) { _, id in model.persistSelection(id) }
    }
}
