import Foundation
import FoundationModels

@Generable
struct AIExtractionBatch {
    @Guide(description: "この会話から抽出した、あとで実行すべき行動。なければ空配列")
    @Guide(.maximumCount(5))
    var todos: [AIExtractedTodo]

    @Guide(description: "この会話から抽出した、あとで読み返す価値のある手順・注意・レクチャー・知識。なければ空配列")
    @Guide(.maximumCount(5))
    var memos: [AIExtractedMemo]
}

@Generable
struct AIExtractedTodo {
    @Guide(description: "短く具体的なやること。例: 資料を提出する")
    var title: String

    @Guide(description: "元会話に実際に出てくる時刻表現。例: 明日10時、15:30、30分後。時刻が無ければ空文字")
    var timeExpression: String

    @Guide(description: "時刻が締切ならtrue（10時までに）。時刻ちょうどに実行する指示ならfalse（10時に）")
    var isDeadline: Bool

    @Guide(description: "timeExpressionから計算したISO 8601日時。timeExpressionが空なら必ず空文字")
    var dueISO8601: String
}

@Generable
struct AIExtractedMemo {
    @Guide(description: "メモの短いタイトル")
    var title: String

    @Guide(description: "後で読んで役立つように、手順や注意点を簡潔にまとめた本文")
    var body: String
}

actor SemanticExtractor {
    private let iso = ISO8601DateFormatter()

    func extract(from text: String, now: Date = .now) async -> ExtractionOutput {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return ExtractionOutput(source: "empty", todos: [], memos: [])
        }

        let model = SystemLanguageModel.default
        let japaneseLocale = Locale(identifier: "ja_JP")
        guard model.isAvailable, model.supportsLocale(japaneseLocale) else {
            return heuristicFallback(clean, now: now, source: "fallback_unavailable_\(String(describing: model.availability))")
        }

        let session = LanguageModelSession(instructions: """
        The person's locale is ja_JP.
        You MUST respond in Japanese.
        あなたは日本語会話を個人用の記録に整理する抽出器です。

        出力は2種類だけです。
        1. todos: ユーザーが後で実行すべき具体的な行動。
        2. memos: 仕事や学習のやり方、手順、ルール、注意、レクチャーなど、後で読み返す価値がある内容。

        重要ルール:
        - 雑談、感想、世間話は保存しない。
        - 同じ内容を言い換えただけなら重複させない。
        - Todoに時刻を付けるのは、会話から時刻まで明確に決められる場合だけ。
        - 「明日まで」「今日中」「来週」など日付だけで時刻が無い場合、dueISO8601 は空文字。
        - 「明日10時」「15時に」「30分後」のように時刻を決められる場合だけ dueISO8601 を返す。
        - 相対日時は、プロンプトで渡す現在日時を基準に変換する。
        - Memoは会話に明示された事実・手順・注意だけを書く。会話にない理由、結論、推測、補足、一般知識を絶対に追加しない。
        - Memoの内容を要約する場合も、意味を変えず、元会話にない情報を加えない。
        - 1つの発言からTodoとMemoの両方が必要なら両方に出してよい。
        - 「明日バイトに行く」「12時に仕事へ行く」のような予定・約束・行動もTodoとして保存する。
        """)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"

        let prompt = """
        現在日時: \(formatter.string(from: now))
        現在タイムゾーン: \(TimeZone.current.identifier)

        会話:
        \(clean)
        """

        do {
            let response = try await session.respond(to: Prompt(prompt), generating: AIExtractionBatch.self)
            let batch = response.content

            let todos = batch.todos.compactMap { item -> ExtractionOutput.Todo? in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let due = hasExplicitTime(item.timeExpression) ? parseISO(item.dueISO8601) : nil
                let notify = due.map { item.isDeadline ? midpoint(from: now, to: $0) : $0 }
                return ExtractionOutput.Todo(title: title, dueAt: due, notifyAt: notify)
            }

            let memos = batch.memos.compactMap { item -> ExtractionOutput.Memo? in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return ExtractionOutput.Memo(title: title.isEmpty ? "メモ" : title, body: body)
            }

            return ExtractionOutput(source: "apple_intelligence", todos: todos, memos: memos)
        } catch {
            // The prototype should still do something useful on devices where the model
            // temporarily can't answer or when the prompt exceeds a model limit.
            let nsError = error as NSError
            let detail = "fallback_generation_failed domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
            return heuristicFallback(clean, now: now, source: detail)
        }
    }

    private func hasExplicitTime(_ expression: String) -> Bool {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let patterns = [
            #"[0-2]?[0-9]\s*時"#,
            #"[0-2]?[0-9]:[0-5][0-9]"#,
            #"[0-9]+\s*分後"#,
            #"[0-9]+\s*時間後"#,
            #"正午"#
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func parseISO(_ raw: String) -> Date? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if let date = iso.date(from: clean) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: clean)
    }

    private func midpoint(from start: Date, to end: Date) -> Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }

    private func heuristicFallback(_ text: String, now: Date, source: String) -> ExtractionOutput {
        // Intentionally conservative fallback. It is only for testing when Apple Intelligence
        // isn't available; the main path uses Foundation Models.
        var todos: [ExtractionOutput.Todo] = []
        var memos: [ExtractionOutput.Memo] = []

        let sentences = text
            .replacingOccurrences(of: "。", with: "。\n")
            .replacingOccurrences(of: "！", with: "！\n")
            .replacingOccurrences(of: "？", with: "？\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            let todoHints = ["しないと", "しておいて", "してください", "やっておいて", "やる", "行く", "行かないと", "向かう", "出勤", "バイト", "仕事", "予定", "提出", "送って", "連絡", "忘れず", "あとで"]
            if todoHints.contains(where: sentence.contains) {
                let due = fallbackDueDate(in: sentence, now: now)
                let notify = due.map { sentence.contains("まで") ? midpoint(from: now, to: $0) : $0 }
                todos.append(.init(title: sentence, dueAt: due, notifyAt: notify))
            }

            let memoHints = ["やり方", "手順", "まず", "次に", "注意", "ルール", "してください", "こうして", "場合は", "使います", "使って"]
            if memoHints.contains(where: sentence.contains) {
                memos.append(.init(title: "会話メモ", body: sentence))
            }
        }

        return ExtractionOutput(source: source, todos: Array(todos.prefix(5)), memos: Array(memos.prefix(5)))
    }

    private func fallbackDueDate(in text: String, now: Date) -> Date? {
        let calendar = Calendar.current

        if let groups = match(#"([0-9]+)\s*分後"#, in: text),
           let minutes = Int(groups[1]) {
            return calendar.date(byAdding: .minute, value: minutes, to: now)
        }

        if let groups = match(#"([0-9]+)\s*時間後"#, in: text),
           let hours = Int(groups[1]) {
            return calendar.date(byAdding: .hour, value: hours, to: now)
        }

        if let groups = match(#"(?:(今日|明日|あした)\s*の?\s*)?(午前|午後)?\s*([0-2]?[0-9])時(?:\s*([0-5]?[0-9])分)?"#, in: text) {
            let dayWord = groups[1]
            let ampm = groups[2]
            guard var hour = Int(groups[3]) else { return nil }
            let minute = Int(groups[4]) ?? 0

            if ampm == "午後" && hour < 12 { hour += 12 }
            if ampm == "午前" && hour == 12 { hour = 0 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

            var base = calendar.startOfDay(for: now)
            if dayWord == "明日" || dayWord == "あした" {
                base = calendar.date(byAdding: .day, value: 1, to: base) ?? base
            }

            guard var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { return nil }
            if dayWord.isEmpty && date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }

        if let groups = match(#"(?:(今日|明日|あした)\s*)?([0-2]?[0-9]):([0-5][0-9])"#, in: text),
           let hour = Int(groups[2]), let minute = Int(groups[3]),
           (0...23).contains(hour), (0...59).contains(minute) {
            var base = calendar.startOfDay(for: now)
            if groups[1] == "明日" || groups[1] == "あした" {
                base = calendar.date(byAdding: .day, value: 1, to: base) ?? base
            }
            guard var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { return nil }
            if groups[1].isEmpty && date <= now {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return date
        }

        return nil
    }

    private func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange) else { return nil }

        return (0..<result.numberOfRanges).map { index in
            let range = result.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
