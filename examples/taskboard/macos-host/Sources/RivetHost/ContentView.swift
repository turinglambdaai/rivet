import SwiftUI
import RivetUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var titleFieldFocused: Bool
    @FocusState private var editButtonFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
                    .disabled(model.titleEditing)
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
                .disabled(!model.ready || model.generating || model.titleEditing)
            }
            .navigationTitle("Rivet Taskboard")
            .frame(minWidth: 280)
        } detail: {
            if let task = model.selectedTask {
                VStack(alignment: .leading, spacing: 18) {
                    if model.titleEditing {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Task title (session-only)", text: $model.titleDraft)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("edit-task-title")
                                .focused($titleFieldFocused)
                                .onExitCommand { model.discardTitleEdit() }
                                .disabled(model.titleSaving)
                            VStack(alignment: .leading, spacing: 8) {
                                Button("Apply for this session") { model.saveTitleEdit() }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("save-task")
                                Button("Discard draft", role: .cancel) {
                                    model.discardTitleEdit()
                                }
                                .accessibilityIdentifier("cancel-task-edit")
                            }
                            .disabled(model.titleSaving)
                            if let error = model.titleError {
                                Text(error)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("task-edit-error")
                            }
                        }
                        .accessibilityElement(children: .contain)
                    } else {
                        Text(task.title)
                            .font(.largeTitle.bold())
                            .accessibilityIdentifier("task-title")
                        Button("Edit title") { model.beginTitleEdit() }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("edit-task")
                            .focused($editButtonFocused)
                            .disabled(!model.ready || model.generating)
                    }
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
                    .disabled(model.generating || model.titleEditing)
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
                    .disabled(!model.ready || model.generating || model.titleEditing)
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
                    .accessibilityIdentifier("application-status")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
            .frame(minHeight: 260)
            chartSection
        }
        .onChange(of: model.selectedID) { _, id in model.persistSelection(id) }
        .onChange(of: model.titleEditing) { _, editing in
            if editing {
                titleFieldFocused = true
                editButtonFocused = false
            } else {
                titleFieldFocused = false
                editButtonFocused = true
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { model.streaming },
                    set: { _ in model.toggleStream() }
                )) {
                    Text("Live timing stream")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("stream-toggle")
                Spacer()
                Text("chart data plane — rivet/chart + RivetUI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            RivetChartView(model: model.chartModel)
                .frame(height: 170)
                .accessibilityIdentifier("timing-chart")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
