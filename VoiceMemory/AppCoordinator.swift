import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let store: AppStore
    let recorder: SpeechRecorder
    private let extractor = SemanticExtractor()


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
    }

    private func receiveFinalTranscript(_ text: String) {
        store.appendTranscript(text)
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.hasPrefix("やること登録") || command.hasPrefix("メモ登録") || command.hasPrefix("メモ検索") {
            let request: String
            if let comma = command.firstIndex(of: "、") {
                request = String(command[command.index(after: comma)...])
            } else { request = "先ほど話していた内容" }
            let context = store.transcriptContext()
            Task { [weak self, extractor] in
                let output = await extractor.extract(from: "依頼: \(command)\n対象議事録:\n\(context)\n検索内容: \(request)")
                await MainActor.run { self?.applyCommandOutput(output, command: command) }
            }
        }
    }

    private func applyCommandOutput(_ output: ExtractionOutput, command: String) {
        store.appendAIStatus(output.source)
        if command.hasPrefix("メモ検索") {
            if let memo = output.memos.first { store.addMemo(title: memo.title, body: memo.body) }
            return
        }
        if command.hasPrefix("メモ登録") {
            for memo in output.memos { store.addMemo(title: memo.title, body: memo.body) }
        } else if command.hasPrefix("やること登録") {
            for todo in output.todos { store.addTodo(title: todo.title, dueAt: todo.dueAt, reminderAt: todo.notifyAt, notificationID: nil) }
        }
    }

}
