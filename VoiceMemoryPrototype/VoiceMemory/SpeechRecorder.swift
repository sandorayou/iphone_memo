import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import Combine

@MainActor
final class SpeechRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "停止中"
    @Published private(set) var errorText: String?

    var onFinalTranscript: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var dictationTranscriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var converter: AnalyzerInputConverter?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var audioPumpTask: Task<Void, Never>?
    private var audioBufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var tapInstalled = false

    func start() async {
        guard !isRecording else { return }
        errorText = nil
        statusText = "準備中…"

        guard await AVAudioApplication.requestRecordPermission() else {
            errorText = "マイクの許可が必要です。設定アプリから許可してください。"
            statusText = "マイク未許可"
            return
        }

        do {
            try configureAudioSession()
            try await configureSpeechPipeline()
            try startAudioEngine()
            isRecording = true
            statusText = "録音中（画面OFFでも継続）"
        } catch {
            await stopInternal()
            errorText = error.localizedDescription
            statusText = "開始に失敗"
        }
    }

    func stop() async {
        guard isRecording || audioEngine.isRunning else { return }
        statusText = "停止処理中…"
        await stopInternal()
        statusText = "停止中"
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func configureSpeechPipeline() async throws {
        let requestedLocale = Locale(identifier: "ja-JP")

        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            // Keep results final-only (so we never duplicate volatile text), but bias the
            // transcriber toward responsiveness so background extraction can happen while
            // a long recording is still running.
            let base = SpeechTranscriber.Preset.transcription
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: base.transcriptionOptions,
                reportingOptions: base.reportingOptions.union([.fastResults]),
                attributeOptions: base.attributeOptions
            )
            self.transcriber = transcriber

            try await prepareAnalyzer(module: transcriber)

            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        guard result.isFinal else { continue }
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        await MainActor.run { self?.onFinalTranscript?(text) }
                    }
                } catch {
                    await MainActor.run {
                        self?.errorText = "文字起こしエラー: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        // Older supported devices can fall back to the on-device dictation model.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            statusText = "互換音声認識を準備中…"
            let base = DictationTranscriber.Preset.longDictation
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: base.contentHints,
                transcriptionOptions: base.transcriptionOptions,
                reportingOptions: base.reportingOptions.union([.frequentFinalization]),
                attributeOptions: base.attributeOptions
            )
            self.dictationTranscriber = transcriber

            try await prepareAnalyzer(module: transcriber)

            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        guard result.isFinal else { continue }
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        await MainActor.run { self?.onFinalTranscript?(text) }
                    }
                } catch {
                    await MainActor.run {
                        self?.errorText = "文字起こしエラー: \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        throw RecorderError.japaneseUnavailable
    }

    private func prepareAnalyzer(module: any SpeechModule) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            statusText = "日本語音声モデルを準備中…"
            try await request.downloadAndInstall()
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw RecorderError.speechAssetsUnavailable
        }

        let converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)

        self.converter = converter
        self.analyzer = analyzer
        self.inputBuilder = inputBuilder

        analysisTask = Task { [weak self] in
            do {
                let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                await MainActor.run {
                    self?.errorText = "音声解析エラー: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.invalidAudioFormat
        }

        let (audioStream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        audioBufferContinuation = continuation

        // One consumer preserves microphone buffer ordering and avoids spawning a Task per buffer.
        audioPumpTask = Task { [weak self] in
            for await buffer in audioStream {
                guard !Task.isCancelled else { return }
                await self?.pushAudioBuffer(buffer)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            // The tap callback owns the incoming buffer only for the callback's work.
            // Make a detached copy before handing it to another asynchronous task.
            guard let detached = Self.detachedCopy(of: buffer) else { return }
            continuation.yield(detached)
        }

        tapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func pushAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard let converter, let inputBuilder else { return }
        do {
            let inputs = try converter.convert(buffer, at: nil)
            for input in inputs {
                inputBuilder.yield(input)
            }
        } catch {
            errorText = "音声変換エラー: \(error.localizedDescription)"
        }
    }

    nonisolated private static func detachedCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }

        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeAudioBufferListPointer(source.audioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData else { continue }

            let byteCount = Int(sourceBuffer.mDataByteSize)
            destinationData.copyMemory(from: UnsafeRawPointer(sourceData), byteCount: byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        return copy
    }

    private func stopInternal() async {
        isRecording = false

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        audioBufferContinuation?.finish()
        audioBufferContinuation = nil
        await audioPumpTask?.value
        audioPumpTask = nil

        if let converter, let inputBuilder {
            if let flushed = try? converter.flush() {
                for input in flushed {
                    inputBuilder.yield(input)
                }
            }
            inputBuilder.finish()
        }

        // Let SpeechAnalyzer consume the final buffers and publish final transcription results.
        // This avoids losing the last few words when the user presses Stop.
        await analysisTask?.value
        await resultTask?.value
        analysisTask = nil
        resultTask = nil
        inputBuilder = nil
        converter = nil
        transcriber = nil
        dictationTranscriber = nil
        analyzer = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum RecorderError: LocalizedError {
    case speechUnavailable
    case japaneseUnavailable
    case invalidAudioFormat
    case speechAssetsUnavailable

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "この端末では新しいSpeechTranscriberが利用できません。"
        case .japaneseUnavailable:
            return "日本語の音声認識モデルを利用できません。"
        case .invalidAudioFormat:
            return "マイクの音声フォーマットを取得できませんでした。"
        case .speechAssetsUnavailable:
            return "音声認識モデルの準備に失敗しました。ネット接続後にもう一度試してください。"
        }
    }
}
