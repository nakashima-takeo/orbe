---
title: エージェント通知の配管（現状）
description: エージェント CLI の hook が状態とセッション ID を .app 同梱 CLI 経由で制御ソケットへ報告し、発信元ペインに保持する配管
updated: 2026-07-22
---

エージェント CLI の hook が現在の状態とセッション ID を**制御ソケットへ報告**し（[control-api](control-api.md) の `report_agent`）、発信元ペインの in-memory 状態に保持する。送信は `.app` 同梱 CLI `orbe-report` が担う。配布物（claude/codex/agy 兼用プラグイン）の構造と導入は [agent-plugin-package](agent-plugin-package.md)。

経路: hook → 配布物内の薄いシム → 同梱 `orbe-report` へ `exec` 委譲 → 制御ソケットへ JSON-RPC 1 行 → `report_agent` を受けて `paneId` で発信元ペインを解決 → 状態 / コマンド名 / セッション ID を保持。

pane identity は env で運ぶ（tty 経路を要さない）。Orbe は**全ペイン**（root も split も）に注入する:
- `ORBE_PANE`（このペインの id）。split は親プロセス env を継承するため、自分の id で上書きしないと親ペイン id で誤報告する。
- `ORBE_SOCK`（このインスタンスの socket パス・隔離インスタンスは `ORBE_STATE_DIR` 解決ぶん）。
- `ORBE_REPORT_BIN`（`.app` 内 `orbe-report` の絶対パス）。`swift run`（バンドル無し）では未解決→未注入で hook は no-op。binary は走っている `.app` 自身のものを指すためプロトコル skew が起きない。

`orbe-report <agent> <state>` の契約:
- `ORBE_PANE`・`ORBE_SOCK` のどちらかが無ければ即 no-op（Orbe 外）。Orbe が動いておらず socket 接続に失敗しても no-op。
- hook の stdin JSON は 1 回だけ読んでパースし、セッション ID 抽出と後述の判定に共用する。セッション ID は claude/codex/agy それぞれのフィールド名を順に見て、無ければ agy の env にフォールバック（いずれも非空のみ）。
- `state=="done"` かつ stdin の `background_tasks` に running が 1 つでもあれば `working` に読み替える——claude の Stop はバックグラウンド作業（bg Bash・bg サブエージェント）残存時も発火するため。フィールド欠落・空配列・型不一致は読み替えずそのまま `done`。判定・抽出は pure 関数として切り出す。
- 接続は 1 リクエスト 1 接続・同期。

状態語: `idle` / `working` / `waiting` / `done` / `clear`。

保持と reset: 状態・セッション ID・コマンド名はペインの in-memory 状態。`clear` で 3 つとも nil。`clear` 以外の更新は state/command を更新し、session_id は新値があれば更新・無ければ維持する（状態遷移をまたいで resume 可能な session_id を保つ）。ペイン消滅で保持値も消える（本配管はファイルに置かない。永続は snapshot 側 → [persistence](persistence.md)）。hook 外の書き込みは復元時の再設定（[persistence](persistence.md)）と done のフォーカス消費（[chrome](chrome.md)）のみ。状態変化は `agent_state` イベントを emit し chrome 更新へ流れる。

対象 CLI: claude / codex / agy の hook 定義あり。取得できる状態は CLI のフック粒度に依存し、claude は全状態、codex は working/waiting/done、agy は working/done のみ（詳細は [agent-plugin-package](agent-plugin-package.md)）。状態の表示（chrome）は本配管の範囲外、セッション ID の永続/resume は [persistence](persistence.md)。
