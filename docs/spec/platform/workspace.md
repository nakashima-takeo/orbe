---
title: workspace
description: 名前付きコンテナの保持・切替・keep-alive、リポジトリに属さないタスクの居場所 Home とそのタスクの作業場、workspace 毎の設定上書き。切替・作成の UI は palette/workspace が持つ
updated: 2026-10-10
---

# workspace

プロジェクトごとにタブ・作業ディレクトリ・設定を分けて持つ、名前付きコンテナ。1 ウィンドウが複数の workspace を束ね、画面に載るのは常にアクティブな 1 つだけ。切替・作成・改名などの UI は [workspace パレット](../palette/workspace.md) が持ち、この文書はコンテナとしての意味論を持つ。

host 所有。ドメイン状態（workspace 配列とアクティブ index と Home を指す値）の実体は Foundation 純粋型 `SessionStore` が所有し、配列 CRUD・active index 補正・MRU 退避先選定はその純メソッド経由で行う。`WindowController` は store を持つ薄いコーディネータで、ビュー mount/reparent・focus・chrome 投影・永続・制御チャネルを担う。タブ閉鎖・選択のような危険な操作は store が「決定（outcome）」を返し、controller がビュー副作用を実行する——判断と副作用を分けてテスト可能に保つ形。

起動時は default（root はホームディレクトリ）と [Home](#home) の 2 つ、または永続からの復元に Home を保証したもの（→ [persistence](persistence.md)）。workspace は root path を持つ。worktree パレットで新しいブランチを作れたときのベースを「前回」として workspace ごとに覚え、次の作成で最初に選ぶ（→ [worktree](../palette/worktree.md)）。書くのはウィンドウだけで、パレットは読むだけ。

## 保持・切替

- **0 タブ（休眠）でもエントリを保持する。** 0 タブ workspace のアクティブ化（切替・復元・削除後の MRU 繰上げ）は空状態を表示し、シェルは自動起動しない。シェルの起こしは新規作成の明示動作にのみ残す。タブを 1 枚も持たない workspace を配列から削除することはない。
- 非アクティブ workspace の `TerminalTab` は保持され、surface は生存する（同一セッション内 keep-alive）。切替は前 workspace のビューを外して切替先を載せるだけで、keep-alive 済みなら再生成ゼロ。背景 workspace は載せず休眠する。
- アクティブ workspace は**全タブ**の surface をウィンドウ階層に載せ、アクティブタブのみ可視・他タブは hidden にする——非アクティブタブもフォーカスを待たず surface が起動して復帰でき、タブ切替が可視/非可視のトグルだけで済む（surface を再生成しない）。
- 隠れタブ・背景 workspace・occluded ウィンドウの surface は**描画のみ**停止する（端末状態・pty は前進。表示復帰時に 1 フレーム描画。可視性同期の契約は [terminal/core](../terminal/core.md)）。
- アクティブ化では可視タブを即時 mount し、未 mount の隠れタブは後続 runloop tick で 1 枚ずつ mount する——1 turn で N 個の surface を同期生成しないため。隠れタブも最終的に必ず mount され surface が起動する不変は保つ（resume 起動も走る）。その mount の途中で別 workspace へ切り替えたら進行中バッチは破棄し（孤児 mount を防ぐ）、次のアクティブ化で再 mount する（冪等）。
- タブはセッション内だけの `activated` を持ち、window hierarchyへのattachを開始する直前にtrueとなる。この materialize 開始の時点で、復元 agent の resume 解決と起動指示の確定を行う（解決できないタブは素のシェルで起きる → [persistence](persistence.md)）。workspaceの `activated` は配下にactivatedタブが1枚以上あるかから導出する現在値で、0タブまたは全タブ未activatedならfalse。workspace内には起動済みタブと休眠タブが混在でき、最後のactivatedタブを閉じれば残るタブがすべて休眠のworkspaceへ戻る。いずれも永続せず、タブは現仕様では一度trueになると閉じるまで戻らない。
- 背景workspaceへ新規タブを明示作成したときは、その1枚だけをオフスクリーンでmaterializeする。computedなworkspaceもactivatedになるが、既存の復元タブは起こさず休眠のまま保つ。通常のworkspace前面化は上記どおり全タブを順次起こす。タブ単位の起床・再休眠を直接操作する公開UI/APIは持たない。
- 人が見ている workspace とタブを変えずに、裏で agent を起こす経路（[秘書](../agent/secretary.md)・[`start_task`](../control/api.md)）は、タブを**選ばずに**起こす。対象が背景 workspace なら上と同じく前面化せずにその 1 枚を起こし、前面の workspace なら隠れタブとして mount する（その workspace のタブがそれしか無いときだけは、空表示のまま見えないタブを作らないよう、選んで見せる）。既にある休眠のタブ（休眠の秘書のタブ）も同じ口で、その 1 枚だけを起こす。
- workspaceの `active`（現在前面にあるか）と `activated`（起動済みタブがあるか）、`lastUsedAt`（前面で利用したMRU）は別の事実である。0タブworkspaceを前面化すると `active: true / activated: false` のままMRUだけを更新する。背景でのmaterialize、背景workspaceのtab close、前面workspaceを0tab化するcloseではMRUを動かさない。一方、前面workspaceでtab close後も残存tabを実際にreselectして表示し続ける場合は、新たなforeground useとしてMRUを更新する。
- 新規 workspace の root path は、作成フォーム経由では入力パス（clone なら clone 先）。制御 API `create_workspace` で rootPath を省略したときはアクティブタブの cwd 由来（不明時はホームディレクトリ）。
- アクティブ workspace の最後のタブを閉じても、その workspace は 0 タブの空状態でアクティブに残る（単一・複数 workspace 問わず。ウィンドウは閉じない）。背景 workspace の最後のタブが閉じても 0 タブのまま残す。
- パレットの詳細メニューからの削除は、アクティブ workspace なら最近使った他 workspace（MRU）を次のアクティブにし、背景 workspace なら現アクティブは不変。Home と最後の通常 workspace は消せない（下記）。

## Home

リポジトリに属さないタスクの居場所で、agent を動かす場所。通常の workspace とは別に必ず 1 つあり、表示名は「Home」（日英同じ）。[秘書](../agent/secretary.md)もここに住む。Home 以外の workspace を「通常の workspace」と呼ぶ。

- **一覧の側が 1 つを指す。** どれが Home かは、アクティブ workspace と同じく一覧が持つ 1 つの値（対象の永続 ID）で表し、workspace 自身は自分の役割を知らない——「ちょうど 1 つ」を要素ごとの印で表すと 0 個や 2 個も表せてしまうため。
- **起動時の保証。** 復元（または新規の default 作成）の後に 1 回、「Home がちょうど 1 つあり、root が専用フォルダ」へそろえる。指している workspace があれば root だけを専用フォルダへ上書きし（名前・位置・タブは保つ）、無い・指す先が見つからなければ「Home」という名前の workspace を末尾に足して指す。active は動かさず、タブも起こさない（作っただけではタブは起きない）。指す先が見つからず足し直したとき、同じフォルダを root に持つ既存の workspace は通常の workspace のまま残る——root の一致では、同じフォルダで作った通常の workspace と区別できないため。
- **専用フォルダ。** state フォルダ（[persistence](persistence.md)。`ORBE_STATE_DIR` があればその下）の `home/`。root は永続値ではなく state フォルダから毎起動導く値で、隔離起動でも本物のフォルダに触れない。state フォルダが決まらなければ保証もフォルダの用意もしない。
- **フォルダの中身は 2 つに分かれる。** Orbe の操作手段（MCP・`orb`）は Orbe 側の事情で変わるので Orbe が持ち、人と AI が書くことは CLAUDE.md が持つ。
  - **Orbe の MCP の使い方**（`.claude/rules/orbe.md`）は、Home で動く claude 全員——秘書も、タスクの作業場で動く claude も、人が手で起こした claude も——が読む。読むのは claude だけで、codex・agy はこのファイルを読まない（Orbe の口の手引きは MCP のツールの説明だけ）。Home とは何か（Home の root の実パスを書き、`list_workspaces` の rootPath がそれの workspace を Home と見分けさせる——「root が祖先の workspace」では root が `~` の default も当てはまる）・タスクの読み書き・[`start_task`](../control/api.md) で作業を始める・待ちの条件と受信・タブと agent の操作と、MCP が使えないときの `orb` を書く。用意のたびにその言語の今の雛形へ書き直す。人や AI の書き換えは残らない。
  - **CLAUDE.md** は、フォルダを作るときにその言語の最小の雛形で 1 回だけ置き、以後は中身を一切見ない——人や AI が書き換えた内容を上書きしないため。CLAUDE.md だけを消しても戻さず、フォルダごと消すと次の用意で作り直す。
  - **秘書の役割の指示はフォルダに置かない。** rules は Home で動く claude 全員が読むので、置くとタスクの作業場で動く claude まで自分を秘書だと思う。秘書の役割は、秘書の会話を起こすときにだけ claude に渡す（[秘書](../agent/secretary.md#秘書の役割の指示)）。
- **用意は UI 言語（日本語／英語）が確定した時点。** 言語選択済みなら起動時の復元より前（復元したタブがフォルダの無いまま起きないため）、初回なら言語選択の確定時。フォルダの作成は作りかけを残さない（一時領域で組んでから置く）。失敗しても次の起動で再挑戦する。
- **消せない・ディレクトリを変えられない・改名はできる。** 削除とディレクトリ変更の可否は SessionStore の判断 1 か所が決め、パレットの詳細メニュー・ウィンドウの操作・[制御 API](../control/api.md) はそれに従う。削除を妨げる理由は 2 つ——Home であること、最後の通常 workspace であること（Home は数に入れない）。通常の workspace をすべて消して Home だけが残ると、新しく起こすタブがリポジトリに属さない Home の root で起きてしまうため。
- **claude の信頼が一度要る。** Home は git の外の新しいフォルダなので、claude はそこで最初に起きるとき、フォルダの信頼の対話を出す。Orbe は利用者の claude の設定に触れず、人が一度答える（秘書のタブで出たときは、応えない秘書の知らせがそのタブを指す → [秘書](../agent/secretary.md#応えない秘書を知らせる)）。信頼は Home の配下（タスクの作業場）にも効く。
- 他は通常の workspace と同じ——切替・タブ・設定上書き・タスクの付き先として普通に使える。Home のタブの agent が workspace を省いてタスクを足せば、Home に付く（[タスク](tasks.md#workspace-の参照)）。

### Home のタスクの作業場

Home に付いたタスクは、worktree の代わりに Home の中のタスクごとのフォルダ `tasks/<ID>-<短い名前>/` で作業する。短い名前はタイトルから作る（パス区切り・空白類・制御文字を `-` に畳み、先頭の一定の長さで切る。空ならタスクの ID だけ）。

- **`start_task` の最初の入力はタスクの ID・タイトルと頼みだけ。** 詳細は agent が MCP で読む——詳細には受信が取り込んだ外の文面が入りうるので、利用者の発話の席に載せない。
- **作るのは [`start_task`](../control/api.md) と、[タスク画面](../palette/tasks.md)で ⌘T を開いたときだけ。** タスクを足しただけでは作らない。既にあれば中身を見ずに使う。
- **タスクの worktree と同じ席に記録する**（[タスク](tasks.md#worktree)）。2 回目以降は記録した場所を使い、消えていれば同じ場所に作り直す。記録が Home の `tasks/` の下に無ければ（リポジトリで始めたタスクを Home に移した）使わず、ID と短い名前で決め直す——本体の作業ツリーにフォルダを作ったり、本体を作業場にしたりしないため。
- **git でなくても、作業場とタブの一致が成り立つ。** タスクの worktree の値とタブの連のキーは同じ規則（そのパスを含む git の worktree のルート、git の外ならそのディレクトリ）で揃うので、フォルダで開いたタブのキーとタスクの作業場は等しい。agent がフォルダの中で `git init` しても、根はそのフォルダのまま。作業のブランチは「ブランチなし」（未確定）なのでブランチで絞られず、行の agent の札・右の欄の agent の場所がそのまま効く。
- **Home が git の作業ツリーの中にあると使えない。** state フォルダを git の中に置くと、作業場の根がそのリポジトリになり、作業場の一致と「1 つの作業場は 1 つのタスク」が崩れる。このとき `start_task` は拒み、タスク画面の ⌘T は理由を出していつもの基点で開く。
- **完了しても消さない。** 片付けは人が行う。

## 設定上書き（workspace 毎プロファイル）

各 workspace は**全設定**の上書きを 1 つの均一な設定層で持ち、永続する（→ [persistence](persistence.md)）。値の担体がスコープ非依存の単一型なので、gui.conf 経由の設定も、gui.conf を経由せず chrome へ直配信する設定（エージェントアイコン・タブタイトルフォント → [chrome](../chrome/chrome.md)）も、起動系が読む設定（デフォルトエージェント）も一律に上書きできる。空層は「上書き無し」へ畳む。

解決は global 層に当該 workspace の上書き層を重ねた**実効設定**（項目ごとに「上書き ?? global ?? 既定」。エージェントアイコンのマップだけは非 nil ならマップ全体を差し替える＝per-key マージしない）。反映は集約点 `applyActiveWorkspaceConfig()`（外観同期＋gui.conf 再生成＋状態アイコン更新＋右バー gate 再評価）が担い、アクティブ化（workspace 切替・起動復元・空 workspace アクティブ化）・初回起動・workspace 作成・設定パレット適用で呼ぶ——**画面に載るのは常にアクティブ 1 workspace のみ**なので、gui.conf 再生成＋全 surface 一律 reload で常に正しい。上書きの編集は設定パレットのスコープトグル（[settings](../palette/settings.md)）。上書きの無い workspace は global で動く。
