---
title: エージェント通知の配管（現状）
description: エージェント CLI の hook が状態とセッション ID を .app 同梱 CLI 経由で制御ソケットへ報告し、発信元ペインに保持する配管
updated: 2026-08-01
---

エージェント CLI の hook が現在の状態とセッション ID を**制御ソケットへ報告**し（[control-api](control-api.md) の `report_agent`）、発信元ペインの in-memory 状態に保持する。送信は `.app` 同梱 CLI `orbe-report` が担う。配布物（claude/codex/agy 兼用プラグイン）の構造と導入は [agent-plugin-package](agent-plugin-package.md)。

経路: hook → 配布物内の薄いシム → 同梱 `orbe-report` へ `exec` 委譲 → 制御ソケットへ JSON-RPC 1 行 → `report_agent` を受けて `paneId` で発信元ペインを解決 → 状態 / コマンド名 / セッション ID を保持。

pane identity は env で運ぶ（tty 経路を要さない）。Orbe は**全ペイン**（root も split も）に注入する:
- `ORBE_PANE`（このペインの id）。split は親プロセス env を継承するため、自分の id で上書きしないと親ペイン id で誤報告する。
- `ORBE_SOCK`（このインスタンスの socket パス・隔離インスタンスは `ORBE_STATE_DIR` 解決ぶん）。
- `ORBE_REPORT_BIN`（`.app` 内 `orbe-report` の絶対パス）。`swift run`（バンドル無し）では未解決→未注入で hook は no-op。binary は走っている `.app` 自身のものを指すためプロトコル skew が起きない。
- `ORBE_BUNDLE_ID`（このインスタンスのチャネル identity）。dev / release のプラグインは別枠として両方 enabled になるため、シムが自チャネル以外の呼び出しを落とすのに使う（[agent-plugin-package](agent-plugin-package.md)）。

`orbe-report <agent> <state>` の契約:
- `ORBE_PANE`・`ORBE_SOCK` のどちらかが無ければ即 no-op（Orbe 外）。Orbe が動いておらず socket 接続に失敗しても no-op。
- hook の stdin JSON は 1 回だけ読んでパースし、セッション ID 抽出と後述の判定に共用する。セッション ID は claude/codex/agy それぞれのフィールド名を順に見て、無ければ agy の env にフォールバック（いずれも非空のみ）。
- サブエージェント実行中の hook payload（親と同じセッション ID で届き、サブエージェント識別子を持つ）は報告しない——ペインのセッション状態ではないため。socket へ接続する前に落とす。
  - 既知の制約: permission 待ちの通知はサブエージェント識別子を**持たない**ので、サブエージェント内の承認要求でもペインは `waiting` になる。一方その待ちを解く側（バッチ解決の報告）はサブエージェント識別子を持つので落ちる。結果、サブエージェント内で承認しても `waiting` は即座には解けず、親のバッチが解決した時点まで残る。
  - 既知の制約: teammate の worker が出す承認要求はリーダーのペインへ届くが、リーダーの承認/拒否は hook を発火しない（ツール実行ではないため）。結果、承認しても `waiting` は次の報告が来るまで残る。
- `state=="done"` かつ stdin の `background_tasks` に running が 1 つでもあれば `working` に読み替える——claude の Stop はバックグラウンド作業（bg Bash・bg サブエージェント）残存時も発火するため。フィールド欠落・空配列・型不一致は読み替えずそのまま `done`。判定・抽出は pure 関数として切り出す。
- `waiting` / `done` は表示用の文言と**その出所**も stdin から取り出して載せる（`waiting` は permission 通知の文言〔出所は通知〕、無ければ待っているツールの先頭質問文〔出所はツール〕。`done` は最終アシスタント応答〔出所はツール〕）。出所は**どの payload フィールドから取ったか**そのもので、別途の判定を持たない。trim して空なら載せず、長文は切って制御ソケットの 1 行上限に対して防御する。当該フィールドを持たない CLI は自然に文言なし。
- 接続は 1 リクエスト 1 接続・同期。

状態語: `idle` / `working` / `waiting` / `done` / `clear`。

保持と reset: 状態・セッション ID・コマンド名・文言（出所つき）・状態変化時刻はペインの in-memory 状態。`clear` で全部 nil。`clear` 以外の更新は state/command を更新し、session_id は新値があれば更新・無ければ維持する（状態遷移をまたいで resume 可能な session_id を保つ）。文言は **state の遷移で確定し直し、同じ state が続くあいだツール由来の文言はツール由来でない報告で上書きされない**（それ以外の組み合わせは上書きする）——1 つの待ちを複数の hook が順に報告する CLI があり（claude は AskUserQuestion のダイアログを開く時点で質問文を、その約 6 秒後に汎用の定型文を撃つ）、出所で守らないと具体的な文言が定型文に潰れるため。逆にツール由来でない報告どうしが上書きし合うのは、待ちの主体がこのペインのエージェントとは限らず（teammate の worker が出す承認要求はリーダーのペインへ届き、要求ごとに文言が違う）、保持すると別の待ちの文言が居残るため。状態変化時刻は **state の値が実際に変わったときだけ** now に進める（同値の連続報告で Attention 一覧の並びが暴れない）。ペイン消滅で保持値も消える（本配管はファイルに置かない。永続は snapshot 側 → [persistence](persistence.md)）。hook 外の書き込みは復元時の再設定（[persistence](persistence.md)）と done のフォーカス消費（[chrome](chrome.md)）のみ。状態変化は `agent_state` イベントを emit し chrome 更新へ流れる。

対象 CLI: claude / codex / agy の hook 定義あり。取得できる状態は CLI のフック粒度に依存し、claude は全状態、codex は working/waiting/done、agy は working/done のみ（詳細は [agent-plugin-package](agent-plugin-package.md)）。状態の表示（chrome）は本配管の範囲外、セッション ID の永続/resume は [persistence](persistence.md)。
