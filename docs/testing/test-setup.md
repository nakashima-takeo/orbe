---
title: テスト基盤の導入メモ
description: 新テストアーキテクチャの実現手段・ツール選定・本番および既存テスト改修の要点と落とし穴
updated: 2026-11-22
---

# テスト基盤の導入メモ

> [テストアーキテクチャ](test-architecture.md) の実現方法。導入が済み、コードと設定が正本になったら削除する。

## ランナーと並列化

- **採用**: **XCTest と Swift Testing のターゲット単位ハイブリッド構成**（Swift 6.4.2 ツールチェーン同梱）。`Orbe` の実環境・共有状態からの隔離（`TestIsolation`）が要らない独立ライブラリテストターゲット（`OrbePathsTests`, `OrbeSessionLogTests`, `OrbeReportTests`, `OrbeSoundTests`, `OrbeEditorCoreTests` および新設する純ロジック・CLI/MCP コアテストターゲット）から Swift Testing（`import Testing`）を段階導入してプロセス内並列実行を効かせる。一方、`Orbe` 本体の実環境・プロセス全域の共有状態を隔離する必要がある結合テストターゲット（`OrbeTests`）は、テストメソッドごとの明示的な呼び出しなしに `OrbeTestCase` の継承だけで隔離ハーネスを自動起動する仕組みを維持するため XCTest 一本に留める。
- **棄却**:
  - **Swift Testing への全面一括移行**: 既存 4,447 関数の一括変換リスクが高く、`XCTestObservationCenter` 相当の自動実行フックがないため `OrbeTests` で隔離漏れを招く。また `Orbe` 本体の `static var *Override` 16 箇所・`setenv` 38 箇所を全廃するまでインプロセス並列化できない。
  - **XCTest のみの継続（`--parallel` 有効化）**: テストメソッドごとにプロセスを起動し、そのたびに 112 MB の `OrbeTests` を読み込むため重い。また、パラメータ化・`TestScoping`・ケース単位の繰り返し実行（`ST-0024`）・JSON Event Stream を使えない。
  - **同一ターゲット（`OrbeTests`）内での XCTest と Swift Testing の混在**: macOS の `swift test` は XCTest と Swift Testing を別プロセスで起動するため、Swift Testing 側で `OrbeTestCase.setUp()` が走らず実環境を汚染する。
- **要点**:
  - `.swiftlint.yml` の `xctest_only_runner` ルールの対象を、`Tests/` 全体への一律適用から「`TestIsolation` が必要なターゲット（`Tests/OrbeTests/` 等）限定」へ絞り、独立純ロジックターゲットで `import Testing` を許可する。
  - `OrbeTestSupport` に `TestScratch` の Swift Testing 版（`ST-0007` `TestScoping` ＋ `@TaskLocal` によるケースごとの一時ディレクトリ作成、既存の外部 `/bin/sh` watchdog を共有）を併設する。
  - 共有アサーションヘルパの移行期は Swift 6.4 の `ST-0021`（`SWIFT_TESTING_XCTEST_INTEROP_MODE`）を補助に使う（`swift-tools-version: 6.0` のままでは既定が `limited` となり、Swift Testing のテストの中で呼んだ XCTest のアサート失敗がテスト失敗にならず警告止まりになるため（XCTest のテストの中の `#expect`・`Issue.record` の失敗はテスト失敗になる）、混在ヘルパを使う場合は `swift-tools-version` 引き上げまたは環境変数 `SWIFT_TESTING_XCTEST_INTEROP_MODE` の設定を行う）。
  - Swift Testing 導入済みターゲットでは、flaky 調査時に Swift 6.4 の `swift test --repeat-until fail --maximum-repetitions <N>` を活用する（CI の無条件リトライには使わない）。

## ターゲット構成と非テストの分離

- **採用**: **SwiftPM 単独構成を維持したまま、本体ロジックのライブラリ切り出しと非テストのターゲット分離を行う**。
  - `orbe-cli`・`orbe-mcp` を薄いエントリポイント（`main.swift`）＋独立ライブラリターゲット（`OrbeCliCore` / `OrbeMcpCore`）へ分離し、それぞれ軽量なユニットテストターゲットを置く。
  - `Orbe` 実行ターゲット本体からライブラリターゲット（例: `OrbeApp`）を切り出す。あわせて、既存 `Tests/OrbeTests` にある共通テスト基盤（`OrbeTestCase`, `TestIsolation` 等）を独立したテスト支援ターゲット（例: `OrbeAppTestSupport`）へ、既存 `Tests/OrbeEditorCoreTests` に閉じている `FakeTextSurface` をエディター共通のテスト支援ターゲット（例: `OrbeEditorTestSupport`）へそれぞれ切り出す。
  - 通常テストではないアサート 0 件の画面キャプチャツール（UI の静止画・操作フローの PNG を生成する `Tests/OrbeTests/Shots/` 46 ファイル 69 件）と、環境変数ゲート付きの性能計測・ローカルでの実機試用用ウィンドウランナー（`FramePerfTests`, `Editor*PerfTests`, `EditorPresentPerfTests`, `EditorRowsTrialTests` 等）を通常テストターゲットから分離する。
- **棄却**:
  - **`Orbe` 本体を分割せずに `OrbeTests` だけを複数 `.testTarget` に分割する案**: Swift 6.4 既定の `swift-build` には独立テストターゲットを直列コンパイルする既知問題（`swiftlang/swift-build#1868`）があり、さらに `GhosttyKit`＋tree-sitter 14 文法＋`Sparkle` を含む ~112 MB のリンクがターゲット数だけ重複してビルド時間が悪化する。
  - **XcodeGen による `.xcodeproj` 導入**: SwiftPM 単独方針に反し `Package.swift` と `project.yml` の二重管理になる上、`OrbeSound` が必須とする `.unsafeFlags(["-O"], .when(configuration: .debug))` が Xcode のパッケージ依存解決と衝突する。
  - **Swift Testing `@Tag` のみによる層別実行**: `ST-0025`（`swift test --filter tag:...`）は Swift 6.5 での実装であり、現行の Swift 6.4.2 ツールチェーンには未搭載。当面の層別実行はターゲット名・スイート名規約に対する `--filter` / `--skip` 正規表現で行う。
- **要点**:
  - テストターゲットを追加する前に `OrbeAppTestSupport` を抽出し、`.swiftlint.yml` の `test_isolation_harness` 対象パスを `OrbeApp` に依存する全テストターゲットへ拡張して隔離の穴を防ぐ。
  - `Shots/` や `*PerfTests`・`*TrialTests` を別ターゲットへ移す際は、`scripts/preview-gallery.sh`・`preview-flows.sh`・`preview-editor-rows.sh`・`perf-editor*.sh`、`.claude/skills/visual-check/SKILL.md`、および `#filePath` / `Bundle(for:)` 相対パス参照（84 ファイル）を連動更新する。
  - SwiftPM の `.testTarget` は素の `swift test` で実行対象になるため、分離した画面キャプチャ・性能計測・長時間ファズターゲットは、既定でスキップする手段（環境変数ゲートまたは `--skip`、あるいは SwiftPM Package Traits の利用）と組み合わせる。

## 依存注入・隔離・時刻制御

- **採用**: **テスト用の外部依存ゼロの純 Swift コンストラクタ／クロージャ／プロトコル注入**を基本とする。テスト作業ディレクトリにのみ `@TaskLocal` + `TestScoping` を、プロセス全域・C コールバック境界にのみ既存の `TestIsolation`（テストごとの宣言なしに自動適用）を併用する。
- **棄却**:
  - **`pointfreeco/swift-dependencies` + `swift-clocks` 導入**: 内部実装が `@TaskLocal` のため、Orbe 本体に 157 箇所ある `Task.detached` / `DispatchQueue` / `Timer` / `NotificationCenter` および `libghostty` C コールバックを跨ぐと依存の伝播が切れ、`withEscapedDependencies` の付け忘れが実環境汚染や失敗を招く。さらに本番バイナリへ 5 パッケージ（`swift-syntax` 含む）が連鎖導入され、`NOTICE` / `licenses/` 管理とビルド負荷が増える。
  - **現行 16 個の `static var *Override` による隔離方式の全面維持**: 共有可変状態を使うためプロセス内並列実行と原理的に両立しない。また、この方式には構造上の限界があり、`UserDefaults.standard` への書き込み（cfprefsd による実ホームへの出力）や、初回アクセス時にメモリへ固定化される `CompletionLearning.shared` のテスト間持ち越しを防げない。
- **要点（本番コード側の主な設計変更）**:
  - `WindowController.init()` に依存（永続化・設定・端末ファクトリ・エディターサーフェスファクトリ・通知音・通知センター・Updater・AutomationStore・クロック）を注入可能にし、起動副作用（実 PTY spawn、Sparkle 初期化、バックグラウンド PATH 走査、SQLite オープン）をコンポジションルートへ分離する。
  - `extension WindowController` に同居する業務ロジック（`TaskWorkStart`, `AutomationNotice`, `WorktreePalette` 配線, `TaskPalette` PR 紐付け, `WaitContinue`）および `MenuBarController` の時間・判断ロジックを独立した型へ切り出す。
  - `ControlServer` をインスタンス生成可能にし、テストごとに独立した `EventHistory` と `target` を持てるようにする（`TerminalTab.agentSlot` からの `ControlServer.shared` 直呼びも注入へ移行）。
  - `UpdaterService` / `MenuBarController` / `StatusRowView` へ `UserDefaults`（またはストア抽象）を注入し、`UserDefaults.standard` 直参照を廃止する。
  - `CompletionLearning`・`CompletionEngine` をインスタンス化・リセット可能にし（不可逆な `failed` 固着を廃止）、`TitleGlyphs.notoEmoji` の `static let` による固定化を `BundledResources.root` 連動へ改める。
  - エディター系の強参照静的レジストリ 4 種（`SourceControl`, `ScmAutoFetch`, `BranchPullRequest`, `PullRequestState`）および直呼びしている `RootFiles.shared` / `GitHubCache.shared` を、スコープ所有（ワークスペース／セッション寿命）へ移す。
  - `TestIsolation` を補強し、`beginCase()` へ `MetalTextView.pasteboard` 隔離、`endCase()` へ `NSApp.appearance` 復元を追加する。あわせて、スコープ所有へ移し終えるまでの過渡期に残る `GitHubCache` 等の共有キャッシュも `beginCase()` で初期化する。
  - `Date()` / `CACurrentMediaTime()` / `Timer` / `asyncAfter` 直呼び（`ScmAutoFetch`, `SidebarScrollbar`, `Renderer`, `AutomationRunner+Recount`, `AutomationTrials`, `TaskStore`, `BackgroundRuns`, `MenuBarController`）と固定猶予時間（`GitRunner.terminationGrace`, `GitHubCLI.terminationGrace`, `BackgroundProcess.killGrace` / `drainGrace`）を注入可能にする。

## 画面非表示化とヘッドレス UI テスト

- **採用**: **主ウィンドウ（`OrbeWindow`）の、key の状態・前面化・確認のシートへの応答をテストが決めるサブクラス（`OrbeWindowFake`）への差し替え＋値型によるキー入力の分離＋並べないテスト用ウィンドウ＋届け先のウィンドウを名指ししたキーの配送（`deliverKeyDown`）**。テスト用のウィンドウは並べない（OS の表示の並びに入れない。AppKit の ordered-in にしない）。マウス・ホイールのイベントを AppKit の配送でビューへ届けるテストだけが、ウィンドウを画面外へ並べるテスト支援の 1 か所（`placeOffscreen`）を通る。通常テストで `setActivationPolicy`・`NSApp.activate`・`makeKeyAndOrderFront`・`orderFront`・`orderFrontRegardless` を呼ぶのは、この 1 か所の `orderFront` だけにする。
- **棄却**:
  - **`nalexn/ViewInspector`**: SwiftUI 内部構造のリフレクション依存で macOS/Xcode 更新ごとに破損しやすく、`@FocusState` が公式非サポート。さらに AppKit `NSWindow`・`NSViewRepresentable`（20 箇所）・Metal・`GhosttyKit` を検証できない。
  - **現行の画面外ウィンドウ + `.accessory` + `makeKeyAndOrderFront` + 固定 `pump`（`PaletteCardWindowHarness` 方式）の維持**: 114 件で `activationPolicy` を `.prohibited ↔ .accessory` 間で往復させ、`pump(0.15〜0.6s)` だけで 170 秒以上の固定待ちが発生している。また `.titled` ウィンドウは macOS の `constrainFrameRect` で画面中央へ押し戻されてチラつく。
- **要点**:
  - key の判定は、本番コードが主ウィンドウの `isKeyWindow` と、key になった・key でなくなったときの通知（`NSWindow.didBecomeKeyNotification` / `didResignKeyNotification`）を読む形のまま変えない。`WindowController` は主ウィンドウを init の引数で受け取り、テストは key の状態を自分で決める `OrbeWindow` のサブクラス（`OrbeWindowFake`）を渡す。アプリを前面にしてウィンドウを key にする前面化（起動時・`MenuBarController`・通知のクリック）は `OrbeWindow.bringToFront()` の 1 つの操作にまとめ、テスト用のサブクラスは呼び出された回数を記録するだけにする。`ScmAutoFetch` の `NSApp.isActive` の判定は、静的レジストリからスコープ所有への移し替えと合わせて差し替えられる形にする。以上に合わせて、実画面表示とフォーカス奪取を行っていた 11 テスト（`SurfaceFocusTests`, `WindowControllerAutomationNoticeTests`, `WindowControllerReportAgentTests`）をこのサブクラスによる非表示検証へ書き換える。隔離ハーネスは、アプリの状態（アクティベーションポリシー・前面かどうか）を戻さない。`OrbeTestCase` が、テスト 1 件の始まりの状態を記録し、テストがランループを回すたびと、終わり（`tearDown` の後）に、状態を見て、始まりと比べる（`ScreenIsolation`）。アクティベーションポリシーが変わった（始まりと終わりで見る）・アプリが前面になった・並んでいてディスプレイの範囲と面積を持って重なるウィンドウが増えた・本物のシートが出た（`NSWindow.willBeginSheetNotification`）のどれかを見つけたら、そのテストを失敗させる。検査の対象になるのは、`OrbeTestCase` を継承する `Tests/OrbeTests` のテスト。ランループを 1 度も回さないうちに並べて下ろしたウィンドウなど、検出できない範囲が在る（`ScreenIsolation` の説明に書いてある）。画面に出す実機試用ランナー・性能計測のクラスは、`presentsOnScreen` を宣言して対象から外れる。
  - `TaskPaletteModel+Keys`・`TaskPaletteAutomationModel+Keys`・`BoardAutomationModel`・`WorktreePaletteFieldKeys`・`WorktreePaletteCardKeys` が直接受けている `SwiftUI.KeyPress` について、その扱いはビュー層の薄い変換に留め、モデルは値型キー（キー・修飾・リピートフラグ）を受ける構造にする。あわせて `DSTab` / `SubmitIgnoringKeyRepeat` の `NSApp.currentEvent` 直読みを引数化する。これにより `TaskPaletteCardKeyTests`（72 件）・`BoardAutomationTests`（30 件）・`WorktreePaletteCardKeyTests`（11 件）の大部分を 1ms 未満の純ユニットテストへ移設する。
  - 実画面中央／左下にウィンドウを出していた 5 クラス 20 件（`WindowControllerBoardTests`, `WindowControllerBoardWidgetsTests`, `WindowControllerPaletteKeyTests`, `WorkspaceCreateCaretTests`, `SidebarScrollbarTests`）から不要な前面化を外し、テストの種類ごとに次の形へ移行する。
    - `WindowController` を載せるテスト（`WindowControllerBoardTests`・`WindowControllerBoardWidgetsTests`・`WindowControllerPaletteKeyTests`・`WorkspaceCreateCaretTests`）: 主ウィンドウを並べず、キーを `deliverKeyDown` で主ウィンドウへ届ける。key の状態や前面化を扱うテストは、`WindowController(window:)` に `OrbeWindowFake` を渡す。
    - `WindowController` を介さず、部品だけを載せるテスト: 並べないウィンドウに載せる。エディターの面は `OrbeWindowFake`（`hostEditor` など）に載せる。主ウィンドウの `OrbeWindow.sendEvent` は、日本語入力の変換中に届いたキーを入力欄へ直に渡す。テストのキーも本番と同じくこれを通すテスト（パレットとボードの部品。`PaletteCardWindowTestCase.host`）は、`OrbeWindow` に載せる。それ以外の部品は素の `NSWindow` に載せる。キーをウィンドウの配送で届けるテストは `deliverKeyDown` を使う。ビューのメソッド（`keyDown(with:)` など）を直接呼んでキーを渡すテストは、直接呼ぶままでよい。
    - マウス・ホイールのイベントを AppKit の配送で届けるテスト（`SidebarScrollbarTests` など）: タイトルバーの無いウィンドウに載せ、`placeOffscreen` を通る。
  - 確認のシートは、本番コードが `NSAlert.beginSheetModal(for:)` で自分のウィンドウに出す形のまま変えない。`NSAlert` はウィンドウの公開のシートの API（`beginSheet`・`beginCriticalSheet`）を通るので、`OrbeWindowFake` がこの API を上書きし、シートを画面に出さずに応答待ちとして持つ。テストは `attachedSheet` で確認が出たことを読み、`endSheet(_:returnCode:)` で応答する。主ウィンドウに確認を出すテストは、`WindowController(window:)` に `OrbeWindowFake` を渡す。
  - `BoardAutomationTests` の生座標クリック（`(300, 669)` 等）や `EditorPaneViewTests+TabClose` / `+Sidebar` / `EditorSearchTests+Ground` / `EditorLineMarksTests` の画素座標と RGB 値のハードコード（`c.x - 8` の位置での輝度差判定等）を廃止し、モデル状態・レイアウト矩形・`firstResponder`・アクセシビリティ要素で検証する。
  - 18 ファイルに重複している独自 `pump` ヘルパを廃止し、`layoutSubtreeIfNeeded()`＋条件待機に統一する。固定秒数の待機（`PaletteFitTests` の 0.2s×24 等）は描画完了の確定的シグナルへ置き換える。

## 重い依存を使うテストの高速化と既存テストの刷新

- **採用**: **重い依存を使うテストを「Fake によるユニットテスト化」と「実物テンプレート再利用による厳選した統合テスト」の二段へ振り分け、価値の薄いテスト・重複テスト・実装に密結合したテストは、振る舞いを担保し直した上で削除・置換する**。
- **棄却**:
  - **全 4,447 テストを現行構成のまま残してハードウェア増強や並列度だけで短縮を図る案**: 固定待ち 250 秒超・不要な `WindowController()` 523 回・オンディスク SQLite 516 回・実 git 386 回・三重重複・実装との脆い結合が温存され、CI コストと保守負債が肥大し続ける。
- **要点**:
  - **オンディスク SQLite のインメモリ化**: `AutomationStore` に `SQLiteDatabase.memory()` 用の標準ファクトリを追加し、`AutomationStoreTests`（98 件）や `TaskPaletteModelTests`（115 件、そもそも自動化を使わない）等の 516 テストから毎回のディスク DB 作成・`quick_check`・スキーマ比較を外す。ディスク SQLite は永続化・マイグレーション層（`StateDatabaseTests` 等）に絞る。
  - **実 `git` と FSEvents の削減・テンプレート再利用**: `GitRunner` / `GitRepo` / `GitHubCLI` / `RepoWatcher` の上位利用側（`WorktreeRepoFacts`, `WorktreePaletteDataProvider`, `WorktreeCleaner`, `EditorDiff`, `SourceControl`, `ScmPanel` 等）にプロトコル／クロージャ抽象を入れ、業務ロジックを Fake でユニットテスト化する。実 git 統合テストは `TempGitRepo` をクラス単位 1 回生成＋`FileManager.copyItem` 複製（現行 `GitWorktreeCleanIntegrationTests` の方式）へ統一し、毎テスト 41 回起動（`WorktreeCreateBaseTests`）や 1 テスト 50 コミット（`SourceControlPaneTests+Layers`）、`sleep 4` hook×4（`ScmAutoFetchPanelTests`）、否定条件の固定時間待機 19 箇所（16.5 秒+）を根絶する。
  - **エディター層の契約完成と非描画層の分離**: `TextSurface` プロトコルへ必要な読み取り契約を補完し、`FakeTextSurface` を `OrbeEditorTestSupport` で共有、`EditorDiffSource` の Fake を用意する。これにより `OrbeTests` 25 ファイルの `OrbeEditorEngine` 直ダウンキャスト・72 箇所の実 `MetalTextSurface` 生成・86 件の `EditorDiffTests` 実 git/FSEvents 依存を解消する。さらに `OrbeEditorEngine` の編集・選択・IME・複数カーソル状態を Metal / `RenderThread` 非依存層へ分離し、`EngineTestCase.open` の既定を「構文解析なし・ディスク書込なし」に変え、`SurfaceMultiCursorVSCodeTests`（87 回）や `SurfaceInputMethodTests+NSTextView`（45 回）での毎回の `NSWindow` 生成を廃止する。
  - **CLI / MCP・PTY・JS エンジンの軽量化**: `orbe-cli`・`orbe-mcp` のライブラリ化により、90 メソッドの大半（特に `OrbeMcpProcessTests` での 32 ツール定義と 99 引数バリデーション）をインプロセスユニットテストへ移設し、テスト側の待機ポーリング内で毎回 `orbe-mcp` プロセスを起動する実装も解消する。実バイナリ起動は代表的な疎通確認のみ残す。`TtyDumpTab`（実 PTY + `python3`）はスイート単位で再利用して起動回数を 32 回から数回へ削減する。`CompletionEngineTests` は手書き `EngineHarness` を廃して `CompletionEngine` 本体へ接続し、`JSContext`（1.3 MB バンドル）をスイートで 1 回だけ初期化する。
  - **ファズと重い純ユニットテストの二段分離**: `ZoneTextLayoutTests`（5,000 段落・26.8 秒）・`SyntaxLayersTests`（128 回×20 KB）・`SurfaceFuzzTests`（18,000 ステップ）・`SurfaceZonesTests+Fuzz`（6,000 ステップ）・`EditorDiffTests+Transitions`（実 git 90 ステップ）・`PullRequestStateTests+ReviewOrder`（60,000 ステップ）は、通常のユニットテストを軽量固定シード（数十 ms 以内）に抑え、大量ステップ版を長時間ファズ枠へ分離する。
  - **価値の薄い・脆い・重複したテストの撤去と未カバー領域の補完**: 恒真テスト（`ChromeFontResolverTests.testEmojiFontSettingDrivesResolver` の `nil == nil`）、単独実行不可の順序依存（`TestIsolationTests.testCaseDirIsFreshForEachTest`）、本番定数表の丸写し（`SettingsRegistryTests`, `SettingsResolutionTests`）、英文プロンプト／日本語 UI 文言／行 index／CLI 引数添字のハードコード（`AutomationNodePassPromptTests`, `SettingsPalette*`, `ClaudeHeadlessTests`）、3 ターゲット間の三重重複（Git 変更マーカー・検索ハイライト・Diff 行並び）を整理する。あわせて未カバー領域（`MenuBarController` 判断部、`CompletionEngine` 実体、`SoundPlayer` フォールバック、`UpdaterService` 状態遷移、`SurfaceView` 検索/スクロール/補完、`WorktreePaletteDataProvider+Clean`、`BoardModel`、`Secretary` 単体）を補完する。

## 静的ルール・生成物・隔離実証

- **採用**: **SwiftLint カスタムルール拡張**＋**`.app` 静的検査テスト／スクリプト**＋**`scripts/verify-test-isolation.sh` の Swift Testing 対応および定期 CI 編入**。
- **棄却**:
  - **レビューや口頭約束だけでテスト品質を維持する運用**: AI が大量にテストを書く開発体制では、機械的ゲートがない規律は数 PR で形骸化する（実際に `OrbeTests` 25 ファイルで `editor_engine_composition_seam` と同等の境界が破られていた）。
- **要点**:
  - `.swiftlint.yml` に新設・改定するカスタムルール:
    - 通常テストでの画面前面化・フォーカス奪取禁止（`setActivationPolicy`, `NSApp.activate`, `NSApplication.shared.activate`, `makeKeyAndOrderFront`, `orderFront`, `orderFrontRegardless` と、ウィンドウを並べる API（`orderBack`, `order(_:relativeTo:)`, `setIsVisible`, `showWindow`）を `Tests/` の全体で error にする）。除外するのは、ウィンドウを画面外へ並べるテスト支援のファイル（`OffscreenWindowPlacement.swift`）と、画面に出す実機試用ランナー・性能計測のファイル（`EditorRowsTrialTests`・`EditorPresentPerfTests`）。後者は、別ターゲットへ分離するまでの間、ファイル名で除外する。別のルールが、`presentsOnScreen` の宣言を、基底クラスと、画面に出すクラスのファイルの外で error にする。
    - 通常テストでの固定待機禁止（`Thread.sleep`, `usleep`, `Task.sleep`, 固定秒数 `RunLoop.*.run(until:)` を検出。正当な例外のみインライン無効化＋理由コメント必須）。
    - `Tests/OrbeTests/` からの `import OrbeEditorEngine` 禁止（本番の `editor_engine_composition_seam` と同じ境界をテスト側にも張る）。
    - `xctest_only_runner` の対象を `TestIsolation` が必要なターゲット限定に絞り、`test_isolation_harness` を `OrbeApp` 依存の全テストターゲットへ拡張。
  - 生成物検査（`main` / 定期 CI）: `scripts/build-app.sh` で dev/release 各構成の `.app` を生成し、`codesign --verify --deep --strict` でのチェックと `PlistBuddy` での項目確認（`CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion`, `OrbeBuildID`）を行う。あわせて、同梱物の存在（`orb`, `orbe-report`, `orbe-mcp`, `Sparkle.framework`, `TreeSitter*.bundle` 16 個, `Orbe_OrbeEditorCore.bundle`, `ghostty`/`terminfo`, フォント, `agent-plugin`）、`docs/design/tokens.json` と `DesignTokens.swift` の過不足ない 1 対 1 一致、および L10n 日英網羅を検証する。
  - `scripts/verify-test-isolation.sh`: 監視対象に `UserDefaults` のテスト実行バイナリ用ドメイン（`xctest` および `swiftpm-testing-helper` の各 plist）を加え、実行本数の判定が XCTest（`Executed N tests`）だけでなく Swift Testing（`Test run with N tests`）も数えるように更新する。

## CI 構成と実行時間プロファイリング

- **採用**: **PR と `main`/定期の 2 段階ワークフロー（`.github/workflows/ci.yml` ＋ 定期/main ジョブ）**、**依存ダウンロード物（`checkouts` + `artifacts` / SwiftPM キャッシュ）に絞った `actions/cache@v6`**、および **`--xunit-output` / Swift Testing `--event-stream-output-path` による所要時間プロファイリング**。見た目の自動 VRT は置かず、既存の `visual-check`（`Shots/`）を運用維持する。
- **棄却**:
  - **`.build` ディレクトリ丸ごとの `actions/cache`**: Orbe の `.build` 実測は 6.5 GB（`.build/out` 単体 2.4 GB、`index-build` 1.6 GB）。GitHub Actions のキャッシュ上限は既定でリポジトリ合計 10 GB（LRU 自動削除。引き上げた超過分は課金）のため複数 PR でスラッシングし、さらに `actions/checkout` の `mtime` リセットでインクリメンタルビルドが無効化されやすい。
  - **`pointfreeco/swift-snapshot-testing` による自動 VRT**: [テストアーキテクチャ](test-architecture.md) で自動 VRT を対象外とし、既存の `visual-check` を継続する方針のため不要。将来 VRT を導入する場合も、次の点に注意する。`swift-snapshot-testing` は `Package.swift` 解決時に `swift-syntax` を引き込む。また `InlineSnapshotTesting` を誤ってリンクすると、非マクロターゲットが `swift-syntax` に依存することになり、SwiftPM はパッケージグラフ全体で `swift-syntax` のプリビルドを使わず、ソースからフルビルドする。加えて、macOS の 1x 固定・`NSHostingView` ラップ・確定的待機は結局自前実装になる（既存 `SnapshotTestSupport.swift` 拡張＋Swift Testing `Attachment` のゼロ依存構成が第一候補）。
  - **PR での全種直列実行（現行 `ci.yml`）**: `macos-26` 標準ランナーは 3 vCPU / 7 GB RAM であり、単一ジョブ直列実行が 60 分タイムアウト設定を強いる原因になっている。
- **要点**:
  - ジョブ構成（`macos-26`）:
    - PR 必須: `lint-format` / `fast-tests`（独立ライブラリ群・ユニット・永続化・制御プロトコル契約・ヘッドレス UI） / `integration-tests`（厳選した実プロセス・実 git・実 PTY・オフスクリーン Metal 描画）。
    - `main` push / 夜間定期: 上記に加え `artifacts`（`build-app.sh` ＋ `.app` 静的検査）/ `long-fuzz`（長時間ファズ）/ `isolation-verify`（`verify-test-isolation.sh`）。
  - キャッシュ対象として `~/Library/Caches/org.swift.swiftpm` および解決済み依存（`GhosttyKit.zip` 展開物・tree-sitter 15 リポジトリ）を `hashFiles('Package.resolved', 'Package.swift')` キーで保持し、`--disable-index-store` 併用でディスク消費（14 GB SSD 枠）とビルド負荷を抑える。
  - 各テストジョブで `--xunit-output`（XCTest）と `--event-stream-output-path`（Swift Testing）を指定して結果を出力し、遅いテスト上位（例: 単体 1 秒超のユニットテスト）をサマリ表示して再肥大化を防ぐ。

## 落とし穴

- **Swift Testing は `XCTestObservationCenter` を通らず別プロセスで走る**: `Tests/OrbeTests` 内に `@Test` を 1 本でも書くと、`swiftpm-testing-helper` が `OrbeTestCase.setUp()` を通らず起動し、実 state dir・実 ghostty 設定・実スピーカーへ直結する。Swift Testing は独立ライブラリテストターゲットに厳格分離する。
- **`ST-0025`（タグフィルタ）は Swift 6.4.2 に未搭載**: `swift test --filter tag:...` は Swift 6.5 機能のため、現行環境ではターゲット名・スイート名規約の `--filter` / `--skip` を使う。
- **`ST-0021` の相互運用モード既定値**: `Package.swift` が `swift-tools-version: 6.0` の間は `limited` 扱いとなり、Swift Testing のテストの中で呼んだ XCTest のアサート失敗がエラーにならず警告になる（XCTest のテストの中の `#expect`・`Issue.record` の失敗はエラーになる）。共有ヘルパの混在を避けるか、環境変数 `SWIFT_TESTING_XCTEST_INTEROP_MODE` や `swift-tools-version` で `complete` 以上を明示設定する。
- **`setenv` / `unsetenv` は POSIX でスレッド非安全（MT-Unsafe）**: テスト内に 38 箇所ある環境変数操作を Swift Testing の並列スレッドから呼ぶと `EXC_BAD_ACCESS` や他テスト汚染を起こす。並列実行するターゲットでは環境変数書き換えを禁止し、子プロセス環境の設定は、`Process.environment` に明示的な辞書を渡す方法のみで行う。
- **`@TaskLocal` は AppKit・GCD・`libghostty` C コールバックで伝播が切れる**: `@TaskLocal` は構造化並行処理内の `TestScratch.caseDir` 等に限定し、UI や C コールバックを跨ぐ依存はコンストラクタ注入（インスタンス保持）で渡す。
- **`@MainActor` テストは再入（reentrancy）する**: Swift Testing で `@MainActor` を付けても、`await` 境界で別テストがメインスレッドに割り込む。プロセス共有の AppKit 状態に触るスイートには `@Suite(.serialized)` を必須とし、Swift Concurrency 協調プール上で `RunLoop.current.run` で長時間ブロックしない。
- **`swift-build#1868` による独立テストターゲットの直列コンパイル**: Swift 6.4 既定の `swift-build` は独立した `.testTarget` を直列コンパイルする。本体モジュールを小さく切り出さずにテストターゲットだけ細分化すると、重複リンクと直列コンパイルでビルド時間が悪化する。
- **GitHub Actions `macos-26` の仮想 GPU（Apple Paravirtual device）と `backingScaleFactor`**: 実機 Apple Silicon と GPU 機能・フォント平滑化・解像度（1x vs 2x）が異なる。Metal デバイス不在環境（サンドボックス等）や仮想 GPU 差異に備え、編集・選択・IME 等の非描画テストは Metal 非依存層へ分離する。
- **AppKit のウィンドウ・ローカルイベント監視の罠**:
  - `.titled` ウィンドウは画面外座標を指定しても `constrainFrameRect` で画面内へ押し戻される（このため、画面外へ並べるテスト支援の `placeOffscreen` は、タイトルバーのあるウィンドウを渡されると、並べる前にテストを失敗させる。画面外表示が要る画面キャプチャツール等では borderless ウィンドウを使う）。
  - 本物のシートが出ている間、AppKit は親のウィンドウを画面の中へ動かす。親を画面外へ置いても、タイトルバーの無いウィンドウにしても、この動きは止まらず、シートのウィンドウはディスプレイの範囲と重なる。確認のシートを出すコードを通るテストは、面を `OrbeWindowFake` に載せ、`WindowController` には `OrbeWindowFake` を渡す。
  - AppKit の `NSScrollView` は、どの画面にも載っていない（`screen` が nil の）ウィンドウでは、ホイールでスクロールしない（macOS 26 で実測。SwiftUI の `ScrollView` の裏も、素の `NSScrollView` も同じ）。画面外へ並べたウィンドウもこれに当たるので、`OrbeWindowFake` は、並べられているのにどの画面にも載っていない間だけ、主ディスプレイに載っていると答える。
  - 並んでいないウィンドウのビューへ、AppKit はマウスのイベントを配らない。ビューのメソッド（`mouseDown` など）を直接呼べば AppKit のビューには届くが、SwiftUI のジェスチャは反応しない。
  - `NSApp.sendEvent` で送った keyDown は、並んでいないウィンドウにも key になれないウィンドウにも届かない。テストのウィンドウはどちらかに当たる。ウィンドウの `sendEvent` へ渡した keyDown は、並んでいないウィンドウでも first responder に届くので、キーはウィンドウを名指しして届ける（`deliverKeyDown`）。
  - key になれるウィンドウは、非アクティブなアプリでは最初のクリックがウィンドウの有効化に使われ、ビューへ届かない。
  - macOS 26 の SwiftUI は、非アクティブなアプリの key でないウィンドウがクリックされると、そのウィンドウが key になれなくても有効化のクリックとみなす。このとき `NSHostingView` の `acceptsFirstMouse` が false なら、クリックをジェスチャへ渡さない（macOS 27 は渡す）。ウィンドウに key と答えさせても（`isKeyWindow` の上書き）、`window.sendEvent` で送っても、クリックは渡らない。`NSHostingView` を本番コードの部品（`BoardView`）が内側で作るのでサブクラスも `allowsWindowActivationEvents` も差し込めず、`placeOffscreen` は並べている間だけ `NSView.acceptsFirstMouse` の実装を true を返すものに入れ替える。
  - `NSWindow` は既定で `isReleasedWhenClosed == true` のため、ARC 下で `close()` を呼ぶと二重解放クラッシュする（`orderOut(nil)`＋`isReleasedWhenClosed = false` を使う）。
  - `NSEvent.addLocalMonitorForEvents` は解除漏れがあると後続の全テストの入力を奪うため、`deinit` / `tearDown` で必ず `removeMonitor` する。ローカルモニタは `NSApp.sendEvent` の中で呼ばれ、`window.sendEvent` やビューのメソッドの直接呼び出しでは呼ばれない。`NSApp.sendEvent` で送ったキーはローカルモニタまでしか届かず、テストのウィンドウ（並べていないウィンドウや key になれないウィンドウ）には届かない。
- **一時ディレクトリの隔離漏れ**: `BackgroundRuns.swift` が一時作業ディレクトリとして `FileManager.default.temporaryDirectory` を直参照しており、`TestScratch` の管理外へ残骸が出るため、注入可能に改める。
