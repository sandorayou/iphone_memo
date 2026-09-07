import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var memos: [MemoItem] = []

    private let todosURL: URL
    private let memosURL: URL
    private let transcriptURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxTranscriptBytes = 1_048_576

    init() {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceMemoryPrototype", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        todosURL = root.appendingPathComponent("todos.json")
        memosURL = root.appendingPathComponent("memos.json")
        transcriptURL = root.appendingPathComponent("transcript.log")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func isRecentTodoDuplicate(title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentThreshold = Date().addingTimeInterval(-30 * 60)
        return todos.contains(where: {
            $0.createdAt >= recentThreshold && normalize($0.title) == normalize(clean)
        })
    }

    func addTodo(title: String, dueAt: Date?, reminderAt: Date?, notificationID: String?) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Very small duplicate guard for the prototype: don't add the same title repeatedly
        // when neighboring transcript chunks overlap.
        let recentThreshold = Date().addingTimeInterval(-30 * 60)
        if todos.contains(where: { $0.createdAt >= recentThreshold && normalize($0.title) == normalize(clean) }) {
            return
        }

        todos.insert(TodoItem(title: clean, dueAt: dueAt, reminderAt: reminderAt, notificationID: notificationID), at: 0)
        persistTodos()
    }

    func addMemo(title: String, body: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBody.isEmpty else { return }

        let recentThreshold = Date().addingTimeInterval(-30 * 60)
        if memos.contains(where: {
            $0.createdAt >= recentThreshold &&
            normalize($0.title) == normalize(cleanTitle) &&
            normalize($0.body) == normalize(cleanBody)
        }) {
            return
        }

        memos.insert(MemoItem(title: cleanTitle.isEmpty ? "メモ" : cleanTitle, body: cleanBody), at: 0)
        persistMemos()
    }

    func deleteTodos(at offsets: IndexSet) {
        let ids = offsets.compactMap { index -> String? in
            guard todos.indices.contains(index) else { return nil }
            return todos[index].notificationID
        }
        for index in offsets.sorted(by: >) {
            guard todos.indices.contains(index) else { continue }
            todos.remove(at: index)
        }
        persistTodos()
        NotificationManager.shared.cancel(ids: ids)
    }

    func deleteMemos(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard memos.indices.contains(index) else { continue }
            memos.remove(at: index)
        }
        persistMemos()
    }

    func appendTranscript(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: .now)
        let line = "[\(stamp)] \(clean)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: transcriptURL.path) {
            if let handle = try? FileHandle(forWritingTo: transcriptURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: transcriptURL, options: .atomic)
        }
        pruneTranscriptIfNeeded()
    }

    private func pruneTranscriptIfNeeded() {
        guard let data = try? Data(contentsOf: transcriptURL), data.count > maxTranscriptBytes else { return }
        let retained = data.suffix(maxTranscriptBytes)
        guard let newline = retained.firstIndex(of: 0x0A) else { return }
        try? Data(retained.suffix(from: retained.index(after: newline))).write(to: transcriptURL, options: .atomic)
    }

    private func load() {
        if let data = try? Data(contentsOf: todosURL), let value = try? decoder.decode([TodoItem].self, from: data) {
            todos = value
        }
        if let data = try? Data(contentsOf: memosURL), let value = try? decoder.decode([MemoItem].self, from: data) {
            memos = value
        }
    }

    private func persistTodos() {
        guard let data = try? encoder.encode(todos) else { return }
        try? data.write(to: todosURL, options: .atomic)
    }

    private func persistMemos() {
        guard let data = try? encoder.encode(memos) else { return }
        try? data.write(to: memosURL, options: .atomic)
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}
