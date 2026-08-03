---
title: テスト実装ロードマップ
description: テストアーキテクチャへ到達するためのスライスと進捗
updated: 2026-08-03
---

# テスト実装ロードマップ

生きた進捗文書。あるべき姿は [test-architecture.md](test-architecture.md) が持つ。

## 現状と到達点

出発点（2026-08-03 時点）。以後更新しない。

| 層 | 現状 | 到達点 |
|---|---|---|
| L0 静的 | SwiftLint / swift format を CI と pre-commit で強制 | 変更なし |
| L1 ユニット | 主戦場。Git パーサ群・`SessionStore`・`SettingsLayer`・`AttentionSnapshot`・`MenuBarArrivalDriver` などが厚い | 穴を埋める。とくに `GitRepo` のメソッド群・`untrackedFileDiff` の境界値 |
| L2 結合 | 観測面が `window.title` 止まり。永続は保存側が厚く**復元側がゼロ**。IME / スクロール / キー翻訳は**テスト 0** | 復元ラウンドトリップ・設定適用の配線・keep-alive・ターミナル入力表面 |
| L3 wire 契約 | **0**。既存の control テストは `WindowController` を直接叩き、検証層を迂回している | socketpair 上の実 `Connection` でプロトコルの語を固める |
| L4 プロセス境界 | **0**。`orbe-cli` は 21 サブコマンド中 0、`orbe-mcp` はテストターゲット自体が無い。唯一の導通確認は `dev-verify.sh`（CI 外・実アプリ起動） | 実バイナリ × in-process `ControlServer`。`dev-verify.sh` を置換 |
| L5 コンポーネント | `MenuBarStatusViewTests` と `ChromeStatusRowTests` のみ | 状態 → 表示とレイアウト数値 |
| L6 見た目 | **0**。`Design*SnapshotTests` は `XCTAssert` 0 件・ゴールデン 0 枚・CI ではスキップされる PNG 生成器 | 1x 固定のゴールデン比較 |
| L7 生成物 | `L10nCompletenessTests` と `OrbePalette` の drift ゲートのみ | `.app` 静的検査・agent-plugin 構成・tokens drift |

**規模**: Sources 28.7k 行に対しテスト 18.5k 行 / 119 ファイル / 1105 関数、CI で 59 秒（うち 15 スキップ）。

**既知 Issue との対応**: 未修正バグはテストが無い層に集中している。#50 #62 #63 #64 #74 は L3/L4、#56 #68 #54 は L2 の復元、#72 #77 は L7。穴を埋める作業がそのまま再発防止網になる。

## スライス

状態: 未着手 / 仕様確定済 / 実装中 / 完了

| # | スライス | 内容 | 依存 | 状態 | テスト仕様書 |
|---|---|---|---|---|---|
| 0 | 基盤足場 | 単一ハーネス（`OrbeTestCase` が点火し `XCTestObservation` が毎テスト隔離。state dir は `ORBE_STATE_DIR` を 90 バイト以下の temp へ向けて隔離し、`control.sock` も自動で追従。永続 4 種と ghostty 設定探索先の override）。`Bundle.main` 直参照 3 箇所を `BundledResources` へ集約。ビルド済み CLI 実行体がテストバンドルの隣にある前提と、その解決規則の固定 | — | 完了 | — |
| 1 | wire 契約 | 制御プロトコルの語を socketpair 上の実 `Connection` で固める。method 名・params キー・エラーコード・`wait_for_event`・framing・不正 JSON。#50 #62 | 0 | 未着手 | — |
| 2 | プロセス境界 | 実 `orbe-cli` / `orbe-mcp` / `orbe-report` を subprocess で駆動。引数解釈・終了コード・stdout・hook 実経路・bare `orb` の PATH 解決。`dev-verify.sh` を置換して廃止。#63 #64 #74 | 0, 1 | 未着手 | — |
| 3 | 復元と移行 | 保存 → 復元 → 再保存のラウンドトリップ。`TabState` decode の非対称（`editor` だけ必須で、無いと全 workspace 消失）・範囲外クランプ・デバウンス。#56 #68 #54 | 0 | 未着手 | — |
| 4 | 既存テストの整理 | assert 0 件の PNG 生成器を「テスト」から出す。自分のクロージャを自分で呼ぶ配線テスト・production を再実装したテスト・13 ファイルに浸透した行 index ハードコード・ヘッドレスで fail する 4 本・条件付きアサートを直す | — | 未着手 | — |
| 5 | ターミナル入力表面 | IME の preedit 同期と Backspace 貫通防止・キー翻訳・スクロールの蓄積と合体 flush。実 `SurfaceView` を直接駆動する | 0 | 未着手 | — |
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
| `DevServerProbe` / `CompletionList` / `StatusRowView+Reorder` の純ロジック切り出し | 数値契約が `private` や `body` 内ローカルに埋まり、PNG を見る以外に検証手段が無い | 7 |
