# WindowsからGitHub ActionsでビルドしてSideStoreへ入れる

このリポジトリは、GitHub ActionsのmacOS runnerで署名なしのiPhone向けIPAを作成します。WindowsにXcodeは不要です。

## GitHubへ登録

GitHubでPrivate repositoryを作成し、このフォルダの中身をリポジトリ直下へpushします。`.github/workflows/build-ios.yml` が見える状態にしてください。

## IPAの作成

1. GitHubの **Actions** を開く
2. **Build unsigned IPA** を選ぶ
3. **Run workflow** を実行
4. 成功後、Artifactsの **VoiceMemory-unsigned-ipa** をダウンロード
5. ZIPを展開して `VoiceMemory-unsigned.ipa` を取得

Appleの署名証明書やApple IDをGitHubへ登録する設定は含めていません。GitHub上では `CODE_SIGNING_ALLOWED=NO` でビルドします。

## SideStoreでインストール

1. WindowsでSideStore公式の初回セットアップを行う（iLoaderを使用）
2. iPhoneにSideStoreとLocalDevVPNを用意する
3. iPhoneでLocalDevVPNを有効にする
4. IPAをiCloud DriveなどでiPhoneへ送る
5. SideStoreからIPAを開いてインストールする

SideStore側でApple Accountを使って再署名してからインストールします。署名なしIPAは単独ではiPhoneにインストールできません。

## 注意

- GitHub Actionsのrunner、Xcodeのバージョン、SideStoreの手順は変更される可能性があります。
- このワークフローはビルドとIPA化までを行います。iPhone実機の録音・文字起こし・バックグラウンド動作までは検証しません。
- 無料Apple Accountの署名には有効期限やアプリ数などの制限があります。SideStore公式の最新手順を優先してください。
