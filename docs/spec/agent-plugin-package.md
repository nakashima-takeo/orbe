---
title: エージェント状態追跡プラグイン（配布物・現状）
description: claude / codex / agy 兼用プラグインパッケージ app/agent-plugin/ の構造・各 CLI の導入契約・.app 同梱と初回自動導入
updated: 2026-07-24
---

`app/agent-plugin/` は claude / codex / agy を 1 ディレクトリで兼ねる状態追跡プラグインパッケージ。各 CLI の hook が Orbe の状態報告シムを呼び、[agent-notify](agent-notify.md) の制御ソケット経路に乗せる。プラグインには binary を入れず純テキストのまま保つ（シムが `.app` 同梱の `orbe-report` を env パスで指す）。プラグイン本体は `plugins/orbe-agent/` に 1 箇所だけ置き（スクリプト重複なし）、claude/codex の marketplace 定義をルートからそこへ向ける。パッケージルートには各 CLI の marketplace 定義と、各 CLI へ冪等導入する `install.sh` を置く。

各 CLI の marketplace/導入契約（実機で確定。「marketplace add 成功」≠「plugin install 成功」）:
- **claude**: ルートの `.claude-plugin/marketplace.json` を読む。`plugin marketplace add <dir>` ＋ `plugin install`。
- **codex**: ルートの `.agents/plugins/marketplace.json` を読み、プラグインは `plugins/<name>/` サブディレクトリに置く規約（`source.path` がルート自身だと取り込まれない）。`plugin marketplace add <dir>` ＋ `plugin add`。
- **agy**: marketplace 不要。本体 subdir を直接指す `plugin install`。導入はステージ先へコピーされ、フック実行 cwd はこのステージ済みプラグインルートになる。

hook からシムを呼ぶ経路も CLI ごとに違う: claude / codex はそれぞれのプラグインルート env 変数を展開して絶対パスで呼ぶ。agy は変数置換が効かないため相対パスで呼ぶ（cwd がステージ済みプラグインルートである契約に依存）。

event→state 対応:
- claude: SessionStart→idle / UserPromptSubmit→working / Notification(permission_prompt|worker_permission_prompt)→waiting / PreToolUse(AskUserQuestion)→waiting / PostToolUse→working / Stop→done / SessionEnd→clear。Notification は matcher で permission 待ちの notification_type に絞る——絞らないと idle（無操作）等でも発火し waiting を誤認するため（matcher に外れた通知はフックコマンド自体が走らない）。
- codex: UserPromptSubmit→working / PermissionRequest→waiting / Stop→done
- agy: PreInvocation→working / Stop→done（agy のフックに SessionStart/Notification/PermissionRequest 相当が無く idle/waiting/clear は取得不可）

`.app` 同梱と初回オンボーディング: `build-app.sh` が `app/agent-plugin/` と状態報告 CLI `orbe-report` をバンドルへ同梱する（実行ビット保持・binary は app 署名対象）。シムはこの binary を env 越しに `exec` する。Orbe は初回起動時にオンボーディング overlay を出す（scrim クリックでは閉じない）。検出未完了の間はスピナーを見せて確定を止め、完了で検出 CLI を見せてデフォルトエージェントを選ばせ（↑↓選択・⌘↑↓ で先頭/末尾へジャンプ・行はホバーで選択が追従し行タップは「始める」と同じ確定〔検出中は不発〕）、「始める」でまず同梱 `agent-plugin/` を **`ORBE_STATE_DIR` 非依存の安定パス**（Application Support 配下・override を見ない。bundle id 由来なのでチャネルごとに別——[channel](channel.md)）へ実体化し（tmp へコピー→原子的差し替え＝冪等・途中失敗でも既存を壊さない・実行ビット保持）、**その安定パスを引数に** `install.sh` をログインシェル PATH 付きでバックグラウンド実行する。安定パスを使うのは `marketplace add` が記録する登録先が消えて dangling しないため（隔離インスタンス起動でも同一パスを登録）。per-CLI のライブ進捗（待機/導入中/完了/失敗/スキップ〔未検出 CLI〕）を表示。失敗 CLI が無ければ導入済みフラグを立てて閉じ、失敗があれば立てずに閉じて次回起動で再表示する。検出ゼロでの「始める」は導入を走らせずフラグも立てずに閉じる。`install.sh` は各 CLI を検出し開始時・完了時に 1 行ずつ状態を出力（Orbe が行ストリームで読む）、冪等導入し、ハングはタイムアウトで打ち切る。`.app` 同梱が無い（`swift run`）か導入済みならオンボーディングは出ない。
