import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var todos: [TodoItem] = []
    @Published private(set) var memos: [MemoItem] = []
    @Published private(set) var recentTranscript: [TranscriptEntry] = []
    @Published private(set) var aiStatusLog = ""
    @Published var selectedMemoID: UUID?

    private let todosURL: URL
    private let memosURL: URL
    private let transcriptURL: URL
    private let recentTranscriptURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxTranscriptBytes = 1_048_576
    private let transcriptFileLimit = 10
    private let transcriptSegmentBytes = 10 * 1024 * 1024
    private let aiStatusURL: URL

    init() {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoiceMemoryPrototype", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        todosURL = root.appendingPathComponent("todos.json")
        memosURL = root.appendingPathComponent("memos.json")
        transcriptURL = root.appendingPathComponent("transcript-current.txt")
        recentTranscriptURL = root.appendingPathComponent("recent-transcript.json")
        aiStatusURL = root.appendingPathComponent("ai-status.log")

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

    func findMemo(for question: String) -> UUID? {
        let triggers = ["どうする", "やり方", "方法", "教えて", "何だっけ", "どうやる"]
        guard triggers.contains(where: question.contains) else { return nil }
        let terms = question.split { $0 == " " || $0 == "　" || $0 == "？" || $0 == "?" }
            .map(String.init).filter { $0.count >= 2 }
        guard let memo = memos.max(by: { lhs, rhs in
            terms.filter { lhs.title.contains($0) || lhs.body.contains($0) }.count < terms.filter { rhs.title.contains($0) || rhs.body.contains($0) }.count
        }) else { return nil }
        let score = terms.filter { memo.title.contains($0) || memo.body.contains($0) }.count
        return score > 0 ? memo.id : nil
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
        recentTranscript.append(TranscriptEntry(text: clean))
        pruneRecentTranscript()
        persistRecentTranscript()
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
        rotateTranscriptIfNeeded()
    }

    func appendAIStatus(_ source: String) {
        let line = "[\(ISO8601DateFormatter().string(from: .now))] \(source)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: aiStatusURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: aiStatusURL, options: .atomic)
        }
        if let data = try? Data(contentsOf: aiStatusURL), data.count > 64 * 1024 {
            try? Data(data.suffix(64 * 1024)).write(to: aiStatusURL, options: .atomic)
        }
        aiStatusLog = (try? String(contentsOf: aiStatusURL, encoding: .utf8)) ?? aiStatusLog
    }

    private func pruneRecentTranscript() {
        let threshold = Date().addingTimeInterval(-10 * 60)
        recentTranscript = recentTranscript.filter { $0.createdAt >= threshold }
    }

    private func persistRecentTranscript() {
        guard let data = try? encoder.encode(recentTranscript) else { return }
        try? data.write(to: recentTranscriptURL, options: .atomic)
    }

    private func rotateTranscriptIfNeeded() {
        guard let data = try? Data(contentsOf: transcriptURL), data.count > transcriptSegmentBytes else { return }
        let fm = FileManager.default
        let root = transcriptURL.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let archive = root.appendingPathComponent("transcript-\(formatter.string(from: .now)).txt")
        try? fm.moveItem(at: transcriptURL, to: archive)
        let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let transcripts = files.filter { $0.lastPathComponent.hasPrefix("transcript-") && $0.pathExtension == "txt" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        if transcripts.count >= transcriptFileLimit {
            for old in transcripts.prefix(transcripts.count - transcriptFileLimit + 1) {
                try? fm.removeItem(at: old)
            }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: todosURL), let value = try? decoder.decode([TodoItem].self, from: data) {
            todos = value
        }
        if let data = try? Data(contentsOf: memosURL), let value = try? decoder.decode([MemoItem].self, from: data) {
            memos = value
        }
        if let data = try? Data(contentsOf: recentTranscriptURL), let value = try? decoder.decode([TranscriptEntry].self, from: data) {
            recentTranscript = value
            pruneRecentTranscript()
        }
        aiStatusLog = (try? String(contentsOf: aiStatusURL, encoding: .utf8)) ?? ""
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
