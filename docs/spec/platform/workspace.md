---
title: workspace
description: 名前付きコンテナの保持・切替・keep-alive と、workspace 毎の設定上書き。切替・作成の UI は palette/workspace が持つ
updated: 2026-08-18
---

# workspace

プロジェクトごとにタブ・作業ディレクトリ・設定を分けて持つ、名前付きコンテナ。1 ウィンドウが複数の workspace を束ね、画面に載るのは常にアクティブな 1 つだけ。切替・作成・改名などの UI は [workspace パレット](../palette/workspace.md) が持ち、この文書はコンテナとしての意味論を持つ。

host 所有。ドメイン状態（workspace 配列とアクティブ index）の実体は Foundation 純粋型 `SessionStore` が所有し、配列 CRUD・active index 補正・MRU 退避先選定はその純メソッド経由で行う。`WindowController` は store を持つ薄いコーディネータで、ビュー mount/reparent・focus・chrome 投影・永続・制御チャネルを担う。タブ閉鎖・選択のような危険な操作は store が「決定（outcome）」を返し、controller がビュー副作用を実行する——判断と副作用を分けてテスト可能に保つ形。

起動時は既定 workspace 1 つ、または永続からの復元（→ [persistence](persistence.md)）。workspace は root path を持つ。

## 保持・切替

- **0 タブ（休眠）でもエントリを保持する。** 0 タブ workspace のアクティブ化（切替・復元・削除後の MRU 繰上げ）は空状態を表示し、シェルは自動起動しない。シェルの起こしは新規作成の明示動作にのみ残す。タブを 1 枚も持たない workspace を配列から削除することはない。
- 非アクティブ workspace の `TerminalController` は保持され、surface は生存する（同一セッション内 keep-alive）。切替は前 workspace のビューを外して切替先を載せるだけで、keep-alive 済みなら再生成ゼロ。背景 workspace は載せず休眠する。
- アクティブ workspace は**全タブ**の分割ツリーをウィンドウ階層に載せ、アクティブタブのみ可視・他タブは hidden にする——非アクティブタブもフォーカスを待たず surface が起動して復帰でき、タブ切替が可視/非可視のトグルだけで済む（surface を再生成しない）。
- 隠れタブ・背景 workspace・occluded ウィンドウの surface は**描画のみ**停止する（端末状態・pty は前進。表示復帰時に 1 フレーム描画。可視性同期の契約は [terminal/core](../terminal/core.md)）。
- アクティブ化では可視タブを即時 mount し、未 mount の隠れタブは後続 runloop tick で 1 枚ずつ分割 mount する——1 turn で N 個の surface を同期生成しないため。隠れタブも最終的に必ず mount され surface が起動する不変は保つ（resume 起動も走る）。分割 mount の途中で別 workspace へ切り替えたら進行中バッチは破棄し（孤児 mount を防ぐ）、次のアクティブ化で再 mount する（冪等）。
- タブはセッション内だけの `activated` を持ち、window hierarchyへのattachを開始する直前にtrueとなる。workspaceの `activated` は配下にactivatedタブが1枚以上あるかから導出する現在値で、0タブまたは全タブ未activatedならfalse。workspace内には起動済みタブと休眠タブが混在でき、最後のactivatedタブを閉じれば残るタブがすべて休眠のworkspaceへ戻る。いずれも永続せず、タブは現仕様では一度trueになると閉じるまで戻らない。
- 背景workspaceへ新規タブを明示作成したときは、その1枚だけをオフスクリーンでmaterializeする。computedなworkspaceもactivatedになるが、既存の復元タブは起こさず休眠のまま保つ。通常のworkspace前面化は上記どおり全タブを順次起こす。タブ単位の起床・再休眠を直接操作する公開UI/APIは持たない。
- workspaceの `active`（現在前面にあるか）と `activated`（起動済みタブがあるか）、`lastUsedAt`（前面で利用したMRU）は別の事実である。0タブworkspaceを前面化すると `active: true / activated: false` のままMRUだけを更新し、背景でのmaterializeやタブのcloseではMRUを動かさない。
- 新規 workspace の root path は、クイック作成（切替パレットで一致なし名＋Enter）では active ペインの cwd 由来（不明時はホーム）、専用作成フォーム経由では入力パス。
- アクティブ workspace の最後のタブを閉じても、その workspace は 0 タブの空状態でアクティブに残る（単一・複数 workspace 問わず。ウィンドウは閉じない）。背景 workspace の最後のタブが閉じても 0 タブのまま残す。
- パレットの詳細メニューからの削除は、アクティブ workspace なら最近使った他 workspace（MRU）を次のアクティブにし、背景 workspace なら現アクティブは不変（workspace が 1 つだけなら削除不可）。

## 設定上書き（workspace 毎プロファイル）

各 workspace は**全設定**の上書きを 1 つの均一な設定層で持ち、永続する（→ [persistence](persistence.md)）。値の担体がスコープ非依存の単一型なので、gui.conf 経由の設定も、gui.conf を経由せず chrome へ直配信する設定（エージェントアイコン・タブタイトルフォント → [chrome](../chrome/chrome.md)）も、起動系が読む設定（デフォルトエージェント）も一律に上書きできる。空層は「上書き無し」へ畳む。

解決は global 層に当該 workspace の上書き層を重ねた**実効設定**（項目ごとに「上書き ?? global ?? 既定」。エージェントアイコンのマップだけは非 nil ならマップ全体を差し替える＝per-key マージしない）。反映は集約点 `applyActiveWorkspaceConfig()`（外観同期＋gui.conf 再生成＋状態アイコン更新＋右バー gate 再評価）が担い、アクティブ化（workspace 切替・起動復元・空 workspace アクティブ化）・初回起動・workspace 作成・設定パレット適用で呼ぶ——**画面に載るのは常にアクティブ 1 workspace のみ**なので、gui.conf 再生成＋全 surface 一律 reload で常に正しい。上書きの編集は設定パレットのスコープトグル（[settings](../palette/settings.md)）。上書きの無い workspace は global で動く。
