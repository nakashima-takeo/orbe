---
title: エージェントセッションの寿命ログ
description: 同一性（CLI 名 + session_id）の始まりと終わりを追記型の agent-sessions.jsonl に記録し、消えたタブを休眠チケットとして戻せるようにする
updated: 2026-09-06
---

# エージェントセッションの寿命ログ

エージェントタブが外部要因——子プロセスの死・kill・クラッシュ——で閉じても、resume に要る同一性（CLI 名・session_id・どの workspace の・どの cwd で）を失わないための記録。Orbe は「プロセスが死んだタブ」を「人が exit したタブ」と区別なく即座に消し、直後の保存で [workspaces.json](persistence.md) からも消す。この挙動は変えず、**同一性の寿命**を別の追記型ログに記録して、そこから戻せるようにする。

守るのは同一性だけで、素のシェルタブ・明示タイトル・タブの並び・ウィンドウサイズは対象外。session_id を報告しない CLI のタブは同一性を持たないので記録されない。

## 記録するもの

単位は**タブではなく同一性**（command + session_id）。同一性が始まった時と終わった時に 1 行ずつ書く。

- `opened` … タブが resume できる同一性を**得た瞬間**。新規起動なら hook の初回報告で session_id が付いた時、休眠チケットの起床なら resume を実行した時、`/clear` 等で session_id が切り替わった後の新 id。
- `closed` … その同一性が**終わった時**。終わり方（`origin`）は 5 値。
  - `agent` — エージェント自身が終えた。hook の `clear` 報告、または同一タブ内での session_id の切替（旧 id に `closed(agent)`、新 id に `opened`）。hook が終了理由を渡す CLI では `reason`（claude の SessionEnd が渡す `clear` / `logout` / `prompt_input_exit` / `other` 等）を添える。
  - `gesture` / `process` / `controlAPI` — 同一性を持ったままタブが外れた。人のジェスチャ（⌘W・タブ行の中クリック・workspace パレットからの workspace 削除）／プロセス終了（シェル exit・kill・クラッシュ）／制御 API（`close_tab`・`remove_workspace`）。休眠チケットのまま外れた場合も同じ。
  - `unresolved` — 休眠チケットの起床で resume を組み立てられず（CLI 未検出・不正な id）、Orbe が素のシェルとして起こした。
- `closed` だけが `title`（閉じた時点のタブ表示名。[chrome](../chrome/chrome.md) のタブバーと同じ導出）を持つ。人がセッションを見分ける手掛かりは閉じた時点の名前であり、`opened` の時点は既定名しか無いため。タイトルは同一性の属性ではなく閉じた時点の写しで、途中の変更履歴は持たない。

1 つの `opened` に `closed` は高々 1 つ。`opened` があって `closed` が無い同一性が「今生きている」。例外は 1 つ——休眠チケットが起床できずに `unresolved`、または休眠のまま外れて `gesture` / `controlAPI` で終わる場合は、`opened` を挟まない `closed` が続く（復元して起こさずに閉じる、を繰り返せば何本でも。チケットは復元で戻った時点では起きておらず、`opened` は起床時にしか付かないため）。

書かないもの: 同一性が既に終わったタブを閉じても行は増えない。session_id 不明のまま閉じたタブは記録しない。**アプリ終了では書かない**——タブは workspaces.json に休眠チケットとして残るので失われていない。復元でも書かない——チケットを足すだけで、起床時に `opened` が付く。

## どこで決め、どこで書くか

同一性の遷移を起こせるのは**タブだけ**。hook 報告の適用・休眠チケットの起床・store から外れる、の 3 つの入口で、タブが「何が始まり／終わったか（同一性・origin・reason）」を決めて上位へ通知する。タブが store から外れる経路——⌘W・プロセス死・`close_tab`・workspace 削除——はすべて store の 1 つの口を通り、その口が**配列から外す前に**タブへ origin を告げる。workspace 削除に固有の記録処理は無く、削除の経路が gesture / controlAPI を名乗って同じ口を通る。

記録——時刻・所属 workspace の名前と rootPath・cwd・タイトルの付与とファイル追記——は window 側が担う。タブは上位（workspace）を知らない一方向参照を守るため。

## ファイル

state dir（[persistence](persistence.md) と同じ場所。チャネル別・`ORBE_STATE_DIR` 追従）の `agent-sessions.jsonl`。1 行 1 イベントの JSON を追記のみで書き、時刻は UTC・ミリ秒精度の ISO 8601。行の形は制御 API の [`session_log`](../control/api.md) が返す 1 要素と同一で、`origin` / `reason` / `title` は `closed` にだけ現れる（`opened` にこれらが付いた行は読めない行として扱う）。

保持は 30 日。起動時に古い行を落として原子的に書き直し、5MB を超える場合は古い側から落とす（変化が無ければ書き直さない）。書き込み失敗はタブ操作を止めない。Orbe プロセスが唯一の書き手で、起動時に読んだ結果に以後の追記を積んだものをメモリに保つ——⇧⌘T パレットと `restore_sessions` はメモリを読み、`session_log` はファイルを読む。同一プロセスが唯一の書き手なので両者は一致する。

## 復元

復元は「閉じた同一性を、それが属していた workspace に休眠チケットとして足す」1 種類だけ。起動時復元と同じチケットで、起床（materialize 開始）時に resume が解決される。持ち込むのは cwd と同一性だけ——明示タイトルは付かず、位置は新規タブと同じ規則（同じ worktree の連が残っていればその右端、無ければ末尾 → [chrome](../chrome/chrome.md) の連）になる。workspace は rootPath で照合し、無ければログの名前・rootPath で作り直す（workspace ごと失った場合こそ災害の本体で、作り直しは安く可逆）。既に同じ session_id のタブ（live／休眠）があればスキップし、今あるものを消す操作は無い。復元されたものは「閉じたまま戻っていない」の導出から自然に外れる。

入口は 3 つ。人が 1 件ずつ戻すのは [⇧⌘T パレット](../palette/closed-agents.md)、多数を一度に戻すのは制御 API の [`restore_sessions`](../control/api.md)（[orb session](../control/cli.md) と MCP から）。復元後にアクティブ workspace に足したチケットは、[layout](../chrome/layout.md) の mount 規律どおり次の選択操作に続いて順次起床し（起動復元と同じ）、背景 workspace に足したものはその workspace のアクティブ化で起きる。
