# AGENTS

Alt-AltTab は AltTab 代替の Cmd+Tab ウィンドウスイッチャーです。SwiftPM のみで完結する macOS 常駐アプリで、Xcode プロジェクトは持ちません。ウィンドウ単位での切り替え、CGEventTap によるキー入力の横取り、ScreenCaptureKit によるサムネイル表示が中心機能です。

## 主要コマンド

- `swift build`: コンパイル確認。エージェントが変更後にまず実行すべきコマンド。
- `swift test`: `Tests/AltAltTabTests/` の純粋ロジック（MRU 順序、レイアウト計算）のユニットテストを実行する。
- `make app`: リリースビルドしてアプリバンドルを組み立てる（署名込み）。
- `make install`: `/Applications` にインストールして起動する。

テストがあるのは純粋ロジックのみです。CGEventTap やアクセシビリティ権限が絡む部分の動作確認には実機での Cmd+Tab 操作が必要なため、エージェントは基本的に `swift build`（と該当箇所を触った場合は `swift test`）が通ることまでを確認範囲とし、実機での動作確認はユーザーに委ねてください。

## アーキテクチャ

`Sources/AltAltTab/` 配下、18個の Swift ファイルです（表示名は Alt-AltTab、Swift モジュール名はハイフン不可のため AltAltTab のまま。ソースディレクトリも同様）。

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

## 規約・パターン

- **モジュール全体が MainActor デフォルト分離**: `Package.swift` の `swiftSettings: [.defaultIsolation(MainActor.self)]` により、`@MainActor` を明示しなくても全型がメインアクター上で動く前提になっている。新しい型を追加するときもこれに従い、個別に `@MainActor` を付ける必要はない。

- **C コールバック（CGEventTap, AXObserver）は file-scope の `nonisolated func` + `Unmanaged` refcon + `MainActor.assumeIsolated`**: `KeyboardHook.swift` の `keyboardHookCallback` と `FocusObserver.swift` の `focusObserverCallback` が実例。C API に渡すコールバックはキャプチャできない plain 関数である必要があるため、ファイルスコープの `nonisolated func` として書き、対象インスタンスは `Unmanaged.passUnretained(self).toOpaque()` で渡した refcon/userInfo から `Unmanaged<T>.fromOpaque(_:).takeUnretainedValue()` で復元する。run-loop source をメインの run loop に載せているため、コールバックは必ずメインスレッドで発火し、`MainActor.assumeIsolated { ... }` でアクターに戻ってよい。新しい C コールバックを追加する場合もこのパターンを踏襲すること。

- **非 Sendable な値をクロージャに渡す必要がある場合は `nonisolated(unsafe)` ローカル + 健全性コメント**: `KeyboardHook.swift` の `keyboardHookCallback` 内、`nonisolated(unsafe) let ev = event` がその例。「同期的に実行され、並行アクセスがない」という根拠を必ずコメントで残すこと。

- **CF グローバル定数が mutable として import される場合は文字列リテラル + コメント**: `Permissions.swift` の `promptAccessibility()` を参照。`kAXTrustedCheckOptionPrompt` は Swift 6 の並行性チェック下では mutable な global として import され安全に使えないため、実体である文字列リテラル `"AXTrustedCheckOptionPrompt"` を直接使い、その旨をコメントで明記している。同種の private/レガシー API 定数に当たった場合はこの回避策を踏襲する。

- **`SwitcherLayout` にレイアウト定数を集約し、view と panel で共有する**: セルサイズやパネルの余白などの数値は `SwitcherLayout.swift` の1箇所にまとめ、`SwitcherView`（SwiftUI のレイアウト）と `SwitcherPanel`（フレームの算術計算）の両方がそれを参照する。どちらかに値をハードコードして重複させないこと。

- **UI にキーボードハンドリングを書かない**: `SwitcherView` に `.onKeyPress` やフォーカス管理を書いてはいけない。`SwitcherPanel` は `nonactivatingPanel` で key window にならないため機能しないだけでなく、`KeyboardHook` の `CGEventTap` がキー入力の唯一の経路であるという設計を崩す。ホバー/クリックのみ SwiftUI 側で扱う。

- **ログは `logToStderr`**: 独自のログ関数を増やさず、`KeyboardHook.swift` で定義されている `logToStderr(_:)` を使う。`[Alt-AltTab]` プレフィックス付きで stderr に出す、意図的にシンプルな実装。

## 落とし穴

- **再ビルドで TCC が切れる場合がある**: ad-hoc 署名のままだと再ビルドのたびにバイナリの識別情報が変わり、許可した権限が無効になることがある。恒久的な回避策（自己署名証明書 `alt-alttab-dev`）は DEVELOPMENT.md を参照。
- **`swift build` が通っても動作確認にはならない**: イベントタップの実際の動作にはアクセシビリティ権限と実機での Cmd+Tab 操作が必要。ビルドが通ることと、機能が動くことは別。
- **`kAXTrustedCheckOptionPrompt` の型問題**: Swift 6 の並行性チェック下でこの CF 定数を直接使うと mutable global の警告/エラーになる。`Permissions.swift` にあるとおり、文字列リテラルで代替する。

## コミット規約

- 日本語でコミットメッセージを書く。
- 1行目に変更内容の要約、必要であれば箇条書きで詳細を続ける。
- Co-Authored-By のようなフッターは付けない。
