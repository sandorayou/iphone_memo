# Voice Memory Prototype

最小構成のiPhone試作アプリです。

## できること

- `記録開始` を押すとマイク入力を開始
- `UIBackgroundModes = audio` を設定済みなので、画面ロック後も録音を継続
- Apple SpeechAnalyzer + SpeechTranscriber（非対応端末ではDictationTranscriber）で日本語を端末上文字起こし。録音中にも確定結果が届きやすい設定を使用
- 文字起こしは画面に常時表示せず、短い区切りごとにまとめて処理
- Apple Foundation Models で次の2種類に分類
  - メモ: 手順、注意、レクチャー、覚えておく知識
  - やること: あとで実行する行動
- `明日10時`、`15時に`、`30分後` のように時刻まで決められるTodoはローカル通知を予約
- `明日まで`、`今日中` のように時刻が無いTodoはリストには保存するが通知時刻は勝手に作らない
- Todo / Memo は端末内JSONに保存
- 認識済みの生テキストは Application Support 内の `transcript.log` にデバッグ用として保存

## 必要環境

- Xcode 26以降を推奨
- iOS 26.0以上
- iOS 26.0以上を動かせるiPhone（新SpeechTranscriber非対応時はDictationTranscriberへフォールバック）
- Foundation Modelsによる高精度分類にはApple Intelligence対応端末 + Apple Intelligence有効化が必要
  - 利用できない場合は簡易ルールベース抽出にフォールバックします

## 実機で動かす

1. `VoiceMemory.xcodeproj` をXcodeで開く
2. Project > Signing & Capabilities で自分のTeamを選択
3. Bundle Identifierが重複する場合は変更
4. iPhone実機を選択してRun
5. 初回にマイクと通知を許可
6. `記録開始` を押す
7. 画面をロックして会話
8. 数十秒後、または会話が一旦止まった後にアプリを開き、`やること` / `メモ` を確認

## 試しやすい発言

- 「明日の10時に資料を提出する」
  - やること + 10時の通知
- 「帰ったら田中さんにメールしないと」
  - やること、通知時刻なし
- 「この作業はまず会社名を検索して、重複がなければテンプレートBを使ってください」
  - メモ
- 「明日までにレポート出す」
  - やること、時刻指定がないため通知なし

## 試作なので未実装

- 話者識別
- クラウド同期
- 音声ファイルの長期保存
- Memoの高度な統合・更新
- Reminderの完了ボタン / スヌーズ
- アプリ強制終了後の自動録音再開
- 電話などのオーディオ割り込み後の完全自動復帰

## 注意

この試作は「まず実機で常時録音 → 自動整理の体験を確認する」ために機能を絞っています。
他人の会話を録音する場合は、利用場所のルール・プライバシー・適用法令に従ってください。


## 2026-09-07 API再確認メモ

- SpeechAnalyzer / SpeechTranscriber / AssetInventory の呼び出し形はApple現行ドキュメントと照合済み。
- 長時間録音中にも確定文字列を受け取りやすいよう、SpeechTranscriberはfinal-only + fastResults、DictationTranscriberはlongDictation + frequentFinalizationを使用。
- AVAudioEngineのtapで受け取ったPCMバッファは、別Taskへ渡す前にコピーして長時間時のバッファ寿命問題を避ける。
- Foundation Modelsは日本語locale対応を実行時に確認し、使えない場合は簡易ルールへフォールバック。
- この環境にはXcode/iOS SDKがないため、最終的なiOS SDK type-checkと実機挙動はXcode + iPhoneで確認が必要。
