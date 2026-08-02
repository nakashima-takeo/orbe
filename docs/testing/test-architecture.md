---
title: テストアーキテクチャ
description: Orbe のテストが従う層構成・横断方針・各層の責務
updated: 2026-08-03
---

# テストアーキテクチャ

あるべき姿の文書。実装の計画と進捗は [roadmap.md](roadmap.md) が持つ。

## 1. 対象

**形**: macOS ネイティブのターミナルマルチプレクサ（GUI 本体）＋ 3 つの CLI 実行体。表面は 7 つ。

| 表面 | 実体 |
|---|---|
| GUI chrome | SwiftUI のパレット・オーバーレイ・MenuBar・Settings・EditorPane |
| ターミナル表面 | libghostty（キー翻訳・IME・スクロール・マウス） |
| 制御 API | `control.sock` 上の JSON-RPC（外部契約） |
| CLI | `orbe-cli` / `orbe-report` |
| MCP | `orbe-mcp` |
| 永続化 | state dir の JSON（workspaces / settings / app-state / gui.conf） |
| 生成物 | `.app` バンドル・agent-plugin パッケージ・L10n カタログ・`docs/tokens.json` |

**スタック**: Swift 6.0（tools-version、言語モード v5）/ macOS 14+ / SwiftPM のみ（Xcode プロジェクトなし）/ AppKit + SwiftUI 混在 / libghostty を `binaryTarget` の xcframework で取り込み / 外部依存は swift-markdown と Sparkle / CI は GitHub Actions macos-26 で `swift build` + `swift test`。

## 2. テスト戦略

層をまたいで全テストが従う決定。

**ランナーは XCTest 一本。** Swift 6.3 では swift-testing との相互運用が `none` で、両者でアサーションヘルパを共有すると失敗が黙殺される。Swift 6.4 で相互運用が既定 `limited` になった時点で再検討する。

**隔離は単一ハーネスが立てる。** state dir・全 override・ghostty の設定探索先を 1 箇所で立て、テストごとの申告制にしない。申告制は必ず破れる（`GuiConfig` の override を張っているテストは 1 本しかなく、`Config.load()` が前回実行の設定を読み戻す結合が実在する）。

**state dir は 90 バイト以下。** AF_UNIX の `sun_path` は 104 バイト上限で、超えると `ControlServer` が制御 API を無言で無効化する。`$TMPDIR` + UUID は 108 バイトに達するため使わない。

**管理下は実物、管理外のみ差し替える。** 実物で回す: ファイルシステム・git・libghostty・Unix domain socket・自前 CLI バイナリ。差し替える: GitHub API（`gh`）・Sparkle の appcast。

**時間依存は時刻注入の状態機械へ寄せる。** タイマーを内蔵せず、時刻を引数で受けて実時間ゼロで境界を測る（`MenuBarArrivalDriver` が範）。

**`swift test --parallel` を使わない。** クラスごとに別プロセスになり、`ControlServer` の socket を奪い合う。

**プロセス全域のシングルトンに触る層は start/stop を対にする。** `ControlServer.shared` の `target` は weak で、前のテストの `WindowController` が解放済みだと "no window" になる。

**ゴールデン画像は 1x で固定する。** 手元は 2x・GitHub runner は 1x なので、固定しなければ両者で必ず不一致になる。フォントと GPU の微小差は `perceptualPrecision` が引き受ける。

## 3. 層構成

### L0 静的健全性

- **担保する**: 型・lint・format
- **担保しない**: 振る舞い
- **ツール**: SwiftLint `--strict` / `swift format lint --strict`
- **実行**: pre-commit（lefthook）＋ CI

### L1 ユニット（純ロジック）

- **担保する**: 入出力の規則。パーサ・状態機械・解決規則・境界値。コードに書かれた制約（未追跡ファイルの 5MB 上限、先頭 8000 バイトの NUL 判定など）もここで固める
- **担保しない**: 配線・組み立て
- **起動と差し替え**: Foundation のみ。依存は引数で受ける
- **データ**: 不要（値を直接組む）
- **実行**: CI 全量
- **配置**: `Tests/OrbeTests/<型名>Tests.swift`。大きい対象は `<型名>Tests+<話題>.swift` に分割

### L2 プロセス内結合

- **担保する**: アプリの組み立て。永続の復元（保存→復元→再保存のラウンドトリップ）・設定適用の配線・workspace の keep-alive・`SessionStore` と `WindowController` の結合・**ターミナル入力表面**（IME の preedit 同期・キー翻訳・スクロールの蓄積と合体 flush）
- **担保しない**: プロセス境界を越える契約（L3/L4）・見た目（L6）
- **起動と差し替え**: 実 `WindowController`（実 NSWindow ＋ 実 libghostty ＋ 実シェル spawn）。`NSApp.activationPolicy()` は `.prohibited` で画面には出ず、フォーカスも奪わない。IME・キー・スクロールは実 `SurfaceView` を直接駆動する
- **データ**: 単一ハーネスが temp の state dir を立て、全 override と ghostty 設定探索先を隔離する。各テストは自分の `WindowController` を作り、`defer` で後始末する
- **実行**: CI 全量
- **ツール**: XCTest

### L3 wire 契約

- **担保する**: 制御プロトコルの語。method 名・params キー・エラーコード（`-32601` / `-32602` / `-32004` / `-32000` / `-32005`）・`wait_for_event` のフィルタとタイムアウト・行 framing・不正 JSON の扱い
- **担保しない**: ドメインの振る舞い（L2）・実バイナリの引数解釈（L4）
- **起動と差し替え**: **socketpair 上の実 `Connection`**。テストが socketpair の片端を `Connection` に渡し、もう片端から行を書いて応答を読む。`ControlTarget` は Fake。path を持たないので `sun_path` 制約を受けず、`ControlServer.shared` にも触らないため L4 と競合しない
- **データ**: Fake target が返す値をテストが決める
- **実行**: CI 全量
- **ツール**: XCTest ＋ swift-snapshot-testing の `.json` 戦略（応答ペイロードのゴールデン）

### L4 プロセス境界・制御チャネル導通

- **担保する**: 実行体をまたいだ導通。実 `orbe-cli` / `orbe-mcp` / `orbe-report` の引数解釈・終了コード・stdout・組み立てる JSON-RPC。ペインへの env 注入から `orbe-report` が `report_agent` を届けるまでの hook 実経路。bare `orb` の PATH 解決
- **担保しない**: `.app` の起動経路と `AppDelegate` の配線
- **起動と差し替え**: テストプロセス内で `ControlServer.shared.start(target:)` に実 `WindowController` を与え、外部プロセスとして `.build/.../debug/` のビルド済みバイナリを起動する。バイナリ位置は `Bundle(for:).bundleURL` の親から解決する。同梱物の位置は `BundledResources.root` を差し替えて実バイナリを指す
- **データ**: 単一ハーネス（L2 と同じ）。サーバの `socketPath` と子プロセスの `ORBE_STATE_DIR` は同じ値を指す。テスト冒頭で `socketPath` の実値を assert する（空や別値だと `start` が no-op になり、クライアント側は "Orbe not running" と区別できず緑に化ける）
- **実行**: CI 全量
- **ツール**: XCTest ＋ `Process`。子プロセスの env は明示辞書のみで親から継承しない

### L5 コンポーネント

- **担保する**: 状態 → 表示の対応とレイアウトの数値契約。ビューがモデルをどう読むか、幅の配分・折り返し・可視範囲の計算
- **担保しない**: 色・余白・字種（L6）
- **起動と差し替え**: `NSHostingView` を実 `NSWindow` に載せて `fittingSize` / `sizeThatFits` を測るか、切り出した純関数を直接呼ぶ
- **データ**: fixture を引数で与える
- **実行**: CI 全量

### L6 見た目

- **担保する**: 色・余白・字種・状態の視覚的符号化の退行
- **担保しない**: 振る舞い
- **起動と差し替え**: 既存の描画経路（`NSHostingView` を borderless `NSWindow` に載せ、`NSAppearance` を明示して `cacheDisplay`）をそのまま使う。ライブラリはこの部分の面倒を見ないので自前のままにする。**スケールは 1x に固定**する
- **前提条件**: ①描画完了を確定的に待つ（固定 sleep では CI 負荷下で白紙がそのままゴールデンになる）②1 枚 1 テストに分解する（1 メソッド 30 枚超のままだと最初の 1 枚で落ちて残りが見えない）
- **データ**: `DesignSceneFixtures` と Sources 側の `*Fixtures.swift`。stub で外枠だけ描かず、本物のデータを本物のビューに流す
- **実行**: CI 全量
- **ツール**: 比較・許容差・記録モード・差分出力は swift-snapshot-testing（`precision` ＋ `perceptualPrecision`）

### L7 生成物

- **担保する**: 配布物の構成。`.app` の署名と同梱物の存在・`Info.plist` の値・agent-plugin パッケージの構成・L10n カタログの網羅・`docs/tokens.json` と `DesignTokens.swift` の一致
- **担保しない**: `.app` を起動したときの挙動
- **起動と差し替え**: `.app` を**起こさず**静的に検査する（`codesign --verify --deep --strict` / `spctl` / `PlistBuddy` / ファイル存在）。tokens の drift は値の一致だけでなくトークン集合の全単射まで見る（片側だけの追加を検出できないため）
- **実行**: CI 全量

## 4. 担保しないもの

どの層も担当しないと決めたもの。壊れたら実使用で気づくことになる。

- **`.app` の起動経路と `AppDelegate` の配線**（`ControlServer.start` を実際に呼ぶのはここだけ）→ `sandbox-run` スキルで、リリース時と `.app` 構成を変えたときに人が回す
- **性能の実行時間**（起動時間・大量ペイン時の応答）。SLO が定義されていない状態で時間を測ると、マシン差で flaky になるだけで回帰検知にならない。コードに書かれた境界値は L1 が固める
- **TCC 権限が絡む分岐の実環境挙動**（アクセシビリティ・入力監視）。分岐そのものは注入点を作って L1 で固める
- **dev / release 2 チャネル併存時の state・socket 分離**
