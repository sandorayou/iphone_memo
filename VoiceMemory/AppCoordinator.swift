import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let store: AppStore
    let recorder: SpeechRecorder

    @Published private(set) var pendingCharacters = 0
    @Published private(set) var lastExtractionAt: Date?
    @Published private(set) var extractionStatus = "待機中"

    private let extractor = SemanticExtractor()
    private var pendingText = ""
    private var pendingReferenceDate: Date?
    private var debounceTask: Task<Void, Never>?
    private var isExtracting = false

    init(store: AppStore = AppStore(), recorder: SpeechRecorder = SpeechRecorder()) {
        self.store = store
        self.recorder = recorder

        recorder.onFinalTranscript = { [weak self] text in
            self?.receiveFinalTranscript(text)
        }
    }

    func requestNotificationPermission() async {
        _ = await NotificationManager.shared.requestAuthorization()
    }

    func startRecording() async {
        await requestNotificationPermission()
        await recorder.start()
    }

    func stopRecording() async {
        await recorder.stop()
        await flushPendingNow()
    }

    private func receiveFinalTranscript(_ text: String) {
        store.appendTranscript(text)
        if pendingText.isEmpty { pendingReferenceDate = .now }
        if !pendingText.isEmpty { pendingText += "\n" }
        pendingText += text
        pendingCharacters = pendingText.count

        debounceTask?.cancel()

        // If a chunk gets large, process immediately. Otherwise wait for a short pause.
        if pendingText.count >= 800 {
            Task { [weak self] in await self?.flushPendingNow() }
        } else {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                await self?.flushPendingNow()
            }
        }
    }

    func flushPendingNow() async {
        guard !isExtracting else { return }
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        debounceTask?.cancel()
        debounceTask = nil
        let referenceDate = pendingReferenceDate ?? .now
        pendingText = ""
        pendingReferenceDate = nil
        pendingCharacters = 0
        isExtracting = true
        extractionStatus = "内容を整理中…"

        let output = await extractor.extract(from: text, now: referenceDate)

        for memo in output.memos {
            store.addMemo(title: memo.title, body: memo.body)
        }

        for todo in output.todos {
            guard !store.isRecentTodoDuplicate(title: todo.title) else { continue }

            var notificationID: String?
            if let dueAt = todo.dueAt, let notifyAt = todo.notifyAt {
                let reminderAt = notifyAt
                notificationID = await NotificationManager.shared.schedule(title: todo.title, at: reminderAt)
                store.addTodo(title: todo.title, dueAt: dueAt, reminderAt: reminderAt, notificationID: notificationID)
            } else {
                store.addTodo(title: todo.title, dueAt: nil, reminderAt: nil, notificationID: nil)
            }
        }

        lastExtractionAt = .now
        extractionStatus = "待機中"
        isExtracting = false

        // New transcript may have arrived while the model was busy.
        if !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await self?.flushPendingNow()
            }
        }
    }

}
