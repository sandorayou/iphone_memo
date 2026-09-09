import Foundation
import Combine

@MainActor
final class AppCoordinator: ObservableObject {
    let store: AppStore
    let recorder: SpeechRecorder


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
    }

}
