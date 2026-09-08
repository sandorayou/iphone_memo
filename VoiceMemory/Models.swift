import Foundation

struct TodoItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var dueAt: Date?
    var reminderAt: Date?
    var notificationID: String?

    init(id: UUID = UUID(), title: String, createdAt: Date = .now, dueAt: Date? = nil, reminderAt: Date? = nil, notificationID: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.reminderAt = reminderAt
        self.notificationID = notificationID
    }

    enum CodingKeys: String, CodingKey { case id, title, createdAt, dueAt, reminderAt, notificationID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt)
        notificationID = try c.decodeIfPresent(String.self, forKey: .notificationID)
    }
}

struct MemoItem: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }
}

struct TranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

struct ExtractionOutput: Sendable {
    let source: String
    struct Todo: Sendable {
        let title: String
        let dueAt: Date?
        let notifyAt: Date?
    }

    struct Memo: Sendable {
        let title: String
        let body: String
    }

    let todos: [Todo]
    let memos: [Memo]

    init(source: String = "unknown", todos: [Todo], memos: [Memo]) {
        self.source = source
        self.todos = todos
        self.memos = memos
    }
}
