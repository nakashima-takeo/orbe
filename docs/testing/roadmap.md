---
title: テスト実装ロードマップ
description: テストアーキテクチャへ到達するためのスライスと進捗
updated: 2026-08-06
---

# テスト実装ロードマップ

生きた進捗文書。あるべき姿は [test-architecture.md](test-architecture.md) が持つ。

## 現状と到達点

出発点（2026-08-03 時点）。進捗では更新しない（事実誤りの訂正だけは入れる）。

| 層 | 現状 | 到達点 |
|---|---|---|
| L0 静的 | SwiftLint / swift format を CI と pre-commit で強制 | 変更なし |
| L1 ユニット | 主戦場。Git パーサ群・`SessionStore`・`SettingsLayer`・`AttentionSnapshot`・`MenuBarArrivalDriver` などが厚い | 穴を埋める。とくに `GitRepo` のメソッド群・`untrackedFileDiff` の境界値 |
| L2 結合 | 観測面が `window.title` 止まり。永続は保存側が厚く**復元側がゼロ**。IME / スクロール / キー翻訳は**テスト 0** | 復元ラウンドトリップ・設定適用の配線・keep-alive・ターミナル入力表面 |
| L3 wire 契約 | **0**。既存の control テストは `WindowController` を直接叩き、検証層を迂回している | socketpair 上の実 `Connection` でプロトコルの語を固める |
| L4 プロセス境界 | **0**。`orbe-cli` は 16 サブコマンド中 0、`orbe-mcp` はテストターゲット自体が無い。唯一の導通確認は CI 外の手動確認だけ | 実バイナリ × in-process `ControlServer` |
| L5 コンポーネント | `MenuBarStatusViewTests` と `ChromeStatusRowTests` のみ | 状態 → 表示とレイアウト数値 |
| L6 見た目 | **0**。`Design*SnapshotTests` は `XCTAssert` 0 件・ゴールデン 0 枚・CI ではスキップされる PNG 生成器 | 1x 固定のゴールデン比較 |
| L7 生成物 | `L10nCompletenessTests` と `OrbePalette` の drift ゲートのみ | `.app` 静的検査・agent-plugin 構成・tokens drift |

**規模**: Sources 28.7k 行に対しテスト 18.5k 行 / 119 ファイル / 1105 関数、CI で 59 秒（うち 15 スキップ）。

**既知 Issue との対応**: 未修正バグはテストが無い層に集中している。#50 #62 #63 #64 #74 は L3/L4、#56 #68 #54 は L2 の復元、#72 #77 は L7。穴を埋める作業がそのまま再発防止網になる。

## スライス

状態: 未着手 / 仕様確定済 / 実装中 / 完了

| # | スライス | 内容 | 依存 | 状態 | テスト仕様書 |
|---|---|---|---|---|---|
| 0 | 基盤足場 | 単一ハーネス（`OrbeTestCase` が点火し `XCTestObservation` が毎テスト隔離。state dir は `ORBE_STATE_DIR` を 90 バイト以下の temp へ向けて隔離し、`control.sock` も自動で追従。永続・同梱リソース根・プラグイン実体化先・ghostty 設定探索先の override を毎テスト張り直す。補完の学習ストアだけはプロセス級固定で、学習状態はテスト間で持ち越される）。`Bundle.main` 直参照 8 箇所（7 ファイル）を `BundledResources` へ集約。`.swiftlint.yml` の custom rule 3 本で、同梱リソースの直参照・`OrbeTestCase` を継承しないテストクラス・swift-testing の import を error に落とす。ビルド済み CLI 実行体がテストバンドルの隣にある前提と、その解決規則の固定 | — | 完了 | — |
| 1 | wire 契約 | 制御プロトコルの語を socketpair 上の実 `Connection` で固める（`ControlWireTests` 群）。method 名・params キー・エラーコード・成功時の応答キーと宛先への配線・`wait_for_event`・framing・不正入力。前提として `ControlServer` に `adopt(fd:)` を切り出し、不正入力へ `-32700` / `-32600` を返すよう直した。エラーコードの語彙は `docs/spec/control-api.md` の「エラー」節と 1 対 1。#50 #62 | 0 | 完了 | — |
| 2 | プロセス境界 | 実 `orbe-cli` / `orbe-mcp` / `orbe-report` を subprocess で駆動し、テストプロセス内の実 `WindowController` ＋ `ControlServer` へ繋ぐ（`ControlProcessHarness`。子の待機は runloop を回して行い、env は明示辞書のみで親から継承しない）。全 16 サブコマンドのライフサイクル・終了コード・`--json` の出力先・`ORBE_PANE` / `current` の文脈解決・`--workspace` の意味論・hook 実経路・bare `orb` の PATH 解決・`orbe-report` が書く生 1 行の語。**スライス 1 からの持ち越し**だった `get_pane_text` の `scrollback` も実 surface で固定した。`.app` 起動経路と `AppDelegate` 配線は範囲外で、その煙探知は `sandbox-run` が持つ。#63 #64 #74 | 0, 1 | 完了 | — |
| 3 | 復元と移行 | 保存 → 復元 → 再保存のラウンドトリップ。`TabState`・設定層の寛容 decode の境界・範囲外クランプ・デバウンス・旧バージョンファイルからの起動移行。#56 #68 #54 | 0 | 完了 | — |
| 4 | 既存テストの整理 | assert 0 件の PNG 生成器を「テスト」から出す。自分のクロージャを自分で呼ぶ配線テスト・production を再実装したテスト・13 ファイルに浸透した行 index ハードコード・ヘッドレスで fail する 4 本・条件付きアサートを直す | — | 未着手 | — |
| 5 | ターミナル入力表面 | IME の preedit 同期と Backspace 貫通防止・キー翻訳・スクロールの蓄積と合体 flush。実 `SurfaceView` を直接駆動する。**スライス 1 からの持ち越し**——`completion_accept` の `advance` と `completion_update` の `buffer`/`cursor`。前者は popup（`CompletionController`）が生まれないと `completionAccept` が結果を返さず、後者は無応答契約で観測面がゼロ（値の到達は `CompletionController` の内部状態にしか現れない）。補完経路を実際に駆動するときに `CompletionLearning.shared` のリセット可能化も同じ地点で要る | 0 | 未着手 | — |
| 6 | アプリ結合 | 設定適用の配線（scope 別の保存先・ライブ反映）・workspace の keep-alive と全タブ mount。`WindowController.init` の分解が前提。#75 #61 | 0, 3 | 未着手 | — |
| 7 | コンポーネント | 状態 → 表示の対応とレイアウト数値。`MenuBarDropdown`・`StatusRowView` の並び替え計算・`CompletionList` の可視範囲 | 0 | 未着手 | — |
| 8 | 見た目の足場 | 描画完了の確定的待機・1x 固定・1 枚 1 テストへの分解・ゴールデン比較の導入。まず 1 画面で成立を確認してから広げる | 0, 4 | 未着手 | — |
| 9 | 生成物 | `.app` の静的検査（署名・同梱物・`Info.plist`）・agent-plugin パッケージ構成・tokens の全単射 drift ゲート。Swift 側が期待する同梱物の相対パス（`bin/orbe-report`・`agent-plugin/install.sh`・`completion-engine.js`・`zsh/.zshrc`・`orbe-defaults.conf`）と `scripts/build-app.sh` の配置の照合——ずれると全機能が無警告で no-op に倒れる。フォントに対しては `TerminalFontDelegationTests` が同じ論法で番人になっている。#72 #77 | — | 未着手 | — |
| 10 | 外部プロセス異常系 | git の失敗・タイムアウト・部分障害。`GitRunner` への注入点（直参照 25 箇所）が前提。`gh` の 3 分岐フォールバック・`AgentCatalog` の 10 秒タイムアウト。#70 #13 | — | 未着手 | — |
| 11 | カバレッジ可視化 | `swift test --enable-code-coverage` → lcov → PR コメント。閾値ゲートにはしない | — | 未着手 | — |

## 前倒しリファクタ

テストで固める前に直す本番コード変更。上位の網を張ってから、1 件ずつ提案して決める。

| 対象 | 理由 | 必要なスライス |
|---|---|---|
| `WindowController.init` の分解（#75） | 結合層の観測面が `window.title` 止まりの根本原因。70 行で永続 3 種ロード・libghostty 起動・login shell subprocess 起動・プラグイン実体化を全部やる | 6 |
| `MenuBarController` の判断部切り出し（#78） | 295 行の時間ロジックが未検証。`MenuBarArrivalDriver` と同じ時刻注入の形へ | 7 |
| `GitRepo` への runner 注入点 | `GitRunner.shared` 直参照 25 箇所。git の異常系を駆動できない | 10 |
| `UpdaterService` への `UserDefaults` 注入点 | standard domain は cfprefsd がユーザーレコードで解決するため HOME 差し替えでは曲がらず、ハーネスの隔離が届かない。`swift test` が実ホームの `com.apple.dt.xctest.tool.plist` を書き、逆に開発者マシンのシステム設定（`AppleInterfaceStyle`・`AppleActionOnDoubleClick`）がテストへ入り込む | 6 |
| `CompletionLearning.shared` のリセット可能化 | `private init` が初回タッチで in-memory ストアを焼くためテスト間でリセットできない。ハーネスはプロセス級固定で回避しており、per-test の学習状態が要るスライスで必要になる | 5 |
| `DevServerProbe` / `CompletionList` / `StatusRowView+Reorder` の純ロジック切り出し | 数値契約が `private` や `body` 内ローカルに埋まり、PNG を見る以外に検証手段が無い | 7 |
