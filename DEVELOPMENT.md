# DEVELOPMENT

Alt-AltTab の開発者向け情報です。ユーザー向けの使い方は README.md を参照してください。

## 開発環境

ビルドに必須なのは Xcode Command Line Tools（Swift 6.x）だけです。

```sh
xcode-select --install
```

Nix flake + direnv は任意の開発環境です。使う場合は次のいずれかで devShell に入ります。

```sh
nix develop
# もしくは direnv allow
```

devShell が提供するのは `gnumake` と `ffmpeg`（`make gif` 用）だけです。Swift は意図的に nixpkgs から入れていません。nixpkgs の Darwin 向け Swift は 5.x 系で古く、macOS 26 SDK をビルドできないためです。`/usr/bin/swift`（Command Line Tools が提供するシステム Swift）をそのまま使います。

## Make ターゲット

- `app`: リリースビルドし、`build/Alt-AltTab.app` を組み立てて署名する。
- `run`: `app` を実行し、既存プロセスを止めてから起動する。
- `install`: `app` を実行し、`/Applications/Alt-AltTab.app` にコピーして起動する（日常利用向け）。
- `reset-tcc`: アクセシビリティ・画面収録の TCC 許可をリセットする。
- `clean`: `.build` と `build` を削除する。
- `gif`: 画面収録 (.mov) をデモ用 GIF に変換する（後述）。

## アーキテクチャ概要

`Sources/AltAltTab/` 配下、18個の Swift ファイルの役割です（表示名は Alt-AltTab、Swift モジュール名はハイフン不可のため AltAltTab のまま。ソースディレクトリも同様）。

| ファイル | 役割 |
| --- | --- |
| main.swift | エントリポイント。`NSApplication` を起動し、`AppDelegate` がステータスバーメニューと起動時の権限プロンプトを管理する。 |
| AppSettings.swift | UserDefaults を裏付けとした `@Observable` な設定。3つのトグルを保持する。 |
| AXPrivate.swift | private API `_AXUIElementGetWindow` と、AX 属性を読む小さな型付きヘルパー群。 |
| FocusObserver.swift | アプリごとの AX「フォーカスウィンドウ変更」通知を監視し、`CGWindowID` を通知する。 |
| KeyboardHook.swift | `CGEventTap` でシステム全体のキーイベントを監視する、Cmd+Tab セッションの唯一の入力経路。ステートマシンを持つ。 |
| LoginItem.swift | `SMAppService.mainApp` の薄いラッパー。「ログイン時に自動起動」トグルの実体。 |
| MRUTracker.swift | セッションをまたいだウィンドウの MRU（最近使った順）を管理する。 |
| Permissions.swift | アクセシビリティ・画面収録の権限確認とプロンプト、対応する設定画面を開くヘルパー。 |
| SettingsWindow.swift | 設定ウィンドウ（SwiftUI の `Form` に4トグル）を管理する。 |
| SwitcherController.swift | `SwitcherDriving` の実装。セッション開始・選択・コミット・キャンセルと W/H/Q アクションを統括する。 |
| SwitcherLayout.swift | `SwitcherView` と `SwitcherPanel` が共有するレイアウト定数。 |
| SwitcherPanel.swift | `SwitcherView` をホストする、非アクティブ化オーバーレイの `NSPanel`。 |
| SwitcherView.swift | スイッチャーの SwiftUI 表示。キーボード処理は持たず、ホバー/クリックのみ扱う。 |
| ThumbnailService.swift | ScreenCaptureKit を使ったウィンドウサムネイルの取得とキャッシュ。 |
| WindowActions.swift | 選択中ウィンドウに対する閉じる/隠す/終了アクション。 |
| WindowEnumerator.swift | 全アプリの AX ツリーを走査して、切り替え可能なウィンドウ一覧を構築する。 |
| WindowFocuser.swift | 選択したウィンドウを前面に出す一連の処理（un-minimize → raise → activate）。 |
| WindowInfo.swift | 列挙・スイッチャー・UI 層で共有する、1ウィンドウ分の情報。 |

`Tests/AltAltTabTests/` に MRU 順序とレイアウト計算のユニットテストがあります（Swift Testing）。

## CI

`.github/workflows/ci.yml` が push（main）・PR・週次（月曜朝 JST）・手動実行で `swift build -c release` → `swift test` → `make app` を実行します。週次実行は、誰も push しなくても macOS ランナーイメージや Swift ツールチェインの更新でビルドが壊れていないかを検知するためのものです。ランナーは `macos-latest` を使い、ジョブ内でイメージ中の最新 Xcode を明示的に選択します（Swift 6.2 以降が必要なため）。

ローカルでのテストは `make test` で実行します（CLT のみの環境では `Testing.framework` の探索パスが通っていないため、Makefile が必要なパスを補います。素の `swift test` は CI などフル Xcode 環境向けです）。

重要な設計事項:

- **CGEventTap が唯一のキー入力経路**: `KeyboardHook` の `CGEventTap` だけがキー入力を扱う。`SwitcherPanel` は `nonactivatingPanel` で key window にならないため、SwiftUI 側にキーボードハンドリングを書いても機能しない。
- **モジュール全体が MainActor デフォルト分離**: `Package.swift` の `.defaultIsolation(MainActor.self)` により、`@MainActor` を明示しなくても全型がメインアクター上で動く。
- **C コールバックのパターン**: `CGEventTap` や `AXObserver` のコールバックはキャプチャできない plain C 関数である必要があるため、file-scope の `nonisolated func` として定義し、`Unmanaged` の refcon/userInfo 経由で対象インスタンスを復元し、`MainActor.assumeIsolated` でアクターに戻る。run-loop source がメインの run loop 上にあるため、コールバックは常にメインスレッドで発火し、この復帰は安全。
- **private API**: `_AXUIElementGetWindow`（AXPrivate.swift）で AX 要素から `CGWindowID` を得ている。AltTab / Rectangle / yabai も使う、10年以上安定している非公開シンボル。

## 署名と TCC

ad-hoc 署名（証明書なし）のままだと、再ビルドのたびにバイナリの識別情報が変わり、許可した権限が無効になることがあります。その場合は次を実行して権限を許可し直してください。

```sh
make reset-tcc
```

Keychain Access で self-signed の Code Signing 証明書 `alt-alttab-dev` を一度作成しておくと、以降は再ビルドしても権限が持続します。Makefile はこの証明書を自動検出して署名に使用します。

作成手順（実機で確認済み）:

1. キーチェーンアクセスを開く
2. メニューバー「キーチェーンアクセス > 証明書アシスタント > 証明書を作成…」を選択
3. 名前に `alt-alttab-dev` と入力（Makefile がこの名前で検出するため正確に）
4. 固有名のタイプ: 「自己署名ルート」のまま
5. 証明書のタイプ: 「コード署名」に変更して「作成」
6. **信頼設定（忘れやすいので注意）**: 作成しただけでは `CSSMERR_TP_NOT_TRUSTED` で署名に使えません。キーチェーンアクセスの「ログイン > 証明書」タブで `alt-alttab-dev` をダブルクリック →「信頼」を展開 →「コード署名」を「常に信頼」に変更 → ウインドウを閉じてパスワードを入力
7. 確認: 以下で `alt-alttab-dev` が表示されれば有効です

   ```sh
   security find-identity -v -p codesigning
   ```

8. `make run` で署名し直します。初回は「codesign がキーチェーン内の鍵を使用しようとしています」というダイアログが出るので「常に許可」を選択
9. ad-hoc 署名から証明書署名に切り替わるため、このタイミングで一度だけ `make reset-tcc` → 権限の再許可が必要です。以降は再ビルドしても権限が持続します

## デモ GIF の作り方

1. Cmd+Shift+5 で画面収録（「選択部分を収録」で範囲を絞ると軽くなります）を開始し、スイッチャーの操作を実演して停止（.mov がデスクトップに保存されます）
2. 変換:

   ```sh
   make gif IN=~/Desktop/demo.mov          # → demo.gif
   make gif IN=in.mov OUT=out.gif FPS=15 WIDTH=800   # 細かく指定する場合
   ```

ffmpeg は devShell に含まれています。キー操作を画面上に表示したい場合は KeyCastr などの併用がおすすめです。

## デバッグ

ログはすべて stderr に出力されます（`logToStderr`、`[Alt-AltTab]` プレフィックス付き）。`log stream` で追うより、ビルド後のバイナリを Terminal から直接実行したほうが手早く確認できます。

```sh
build/Alt-AltTab.app/Contents/MacOS/Alt-AltTab
```

この方法だとステータスバーアプリとして動きつつ、ログがそのまま Terminal に流れてきます。
