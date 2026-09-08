import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        TabView {
            RecordingView(coordinator: coordinator)
                .tabItem { Label("記録", systemImage: "mic.fill") }

            TodoListView(store: coordinator.store)
                .tabItem { Label("やること", systemImage: "checklist") }

            MemoListView(store: coordinator.store)
                .tabItem { Label("メモ", systemImage: "note.text") }

            TranscriptListView(store: coordinator.store)
                .tabItem { Label("議事録", systemImage: "text.bubble") }
        }
    }
}

private struct TranscriptListView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                if store.recentTranscript.isEmpty {
                    ContentUnavailableView("直近10分の会話はありません", systemImage: "text.bubble")
                } else {
                    ForEach(store.recentTranscript) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.text)
                            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("議事録（直近10分）")
        }
    }
}

private struct RecordingView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var recorder: SpeechRecorder

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.recorder = coordinator.recorder
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 88))
                    .symbolEffect(.pulse, isActive: recorder.isRecording)

                Text(recorder.statusText)
                    .font(.title3.bold())

                if coordinator.pendingCharacters > 0 {
                    Text("未整理の文字: \(coordinator.pendingCharacters)字")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(coordinator.extractionStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error = recorder.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Button {
                    Task {
                        if recorder.isRecording {
                            await coordinator.stopRecording()
                        } else {
                            await coordinator.startRecording()
                        }
                    }
                } label: {
                    Text(recorder.isRecording ? "停止" : "記録開始")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 36)

                Text("記録開始後は画面をロックして構いません。文字起こしは画面には表示せず、会話の区切りごとにメモとやることへ自動整理します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer()
            }
            .navigationTitle("Voice Memory")
        }
    }
}

private struct TodoListView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                if store.todos.isEmpty {
                    ContentUnavailableView("やることはまだありません", systemImage: "checklist")
                } else {
                    ForEach(store.todos) { todo in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(todo.title)
                                .font(.body)
                            if let due = todo.dueAt {
                                Label("期限: \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "flag.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let reminder = todo.reminderAt {
                                    Text("リマインド: \(reminder.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("通知時刻なし")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onDelete(perform: store.deleteTodos)
                }
            }
            .navigationTitle("やること")
        }
    }
}

private struct MemoListView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        NavigationStack {
            List {
                if store.memos.isEmpty {
                    ContentUnavailableView("メモはまだありません", systemImage: "note.text")
                } else {
                    ForEach(store.memos) { memo in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(memo.title)
                                .font(.headline)
                            Text(memo.body)
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text(memo.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: store.deleteMemos)
                }
            }
            .navigationTitle("メモ")
        }
    }
}
