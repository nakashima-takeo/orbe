---
title: エージェント状態追跡プラグイン（配布物）
description: claude / codex / agy 兼用プラグインパッケージ app/agent-plugin/ の構造・各 CLI の導入契約・チャネル別のプラグイン名・.app 同梱と毎起動の実体化
updated: 2026-08-08
---

# エージェント状態追跡プラグイン（配布物）

`app/agent-plugin/` は claude / codex / agy を 1 ディレクトリで兼ねる状態追跡プラグインパッケージ。各 CLI の hook が Orbe の状態報告シムを呼び、[notify](notify.md) の制御ソケット経路に乗せる。プラグインには binary を入れず純テキストのまま保つ（シムが `.app` 同梱の `orbe-report` を env パスで指す）。プラグイン本体は `plugins/<プラグイン名>/` に 1 箇所だけ置き（スクリプト重複なし）、claude/codex の marketplace 定義をルートからそこへ向ける。パッケージルートには各 CLI の marketplace 定義と、各 CLI へ冪等導入する `install.sh` を置く。

## チャネル別のプラグイン名

**プラグイン名（＝marketplace 名＝`plugins/` 直下のディレクトリ名）はチャネルごとに別**で、1 つの名前がパッケージの全出現箇所（両 marketplace 定義の name と source・3 つの plugin 定義の name・agy hooks のトップキー・ディレクトリ名）を通る（[channel](../platform/channel.md)）。**agy は marketplace を持たず plugin 名だけで枠が分かれる**ため、marketplace 名だけ分けても 3 CLI が揃って分かれない。

## 各 CLI の marketplace/導入契約

実機で確定した契約（「marketplace add 成功」≠「plugin install 成功」）。

- **claude**: ルートの `.claude-plugin/marketplace.json` を読む。`plugin marketplace add <dir>` ＋ `plugin install`。**登録先をライブ参照する**ので、登録後に中身を書き換えれば次のセッションから新しい定義が走る。
- **codex**: ルートの `.agents/plugins/marketplace.json` を読み、プラグインは `plugins/<name>/` サブディレクトリに置く規約（`source.path` がルート自身だと取り込まれない）。`plugin marketplace add <dir>` ＋ `plugin add`。**導入時のキャッシュコピーを読む**ので、登録先を書き換えても再導入まで新しい定義は届かない（`plugin list` の PATH 列は登録先を表示するため見分けにくい）。
- **agy**: marketplace 不要。本体 subdir を直接指す `plugin install`。導入はステージ先へコピーされ、フック実行 cwd はこのステージ済みプラグインルートになる。**ステージ済みコピーを読む**ので、codex と同じく再導入まで新しい定義は届かない。

`install.sh` はプラグインディレクトリとプラグイン名を引数で受ける。登録済み判定は名前の**完全一致**で見る——前方一致だと別チャネルの枠を自分のものと誤認し、そのチャネルが永久に自分の枠を登録できない（claude / codex は `<name>@<name>`、agy は JSON 出力中の引用符込みの名前）。

hook からシムを呼ぶ経路も CLI ごとに違う: claude / codex はそれぞれのプラグインルート env 変数を展開して絶対パスで呼ぶ。agy は変数置換が効かないため相対パスで呼ぶ（cwd がステージ済みプラグインルートである契約に依存）。

## チャネル判定シム

シムは**自分と同じチャネルのペインからの呼び出しにだけ応える**。プラグインが持つ `hooks/channel`（実体化時に Orbe が刻む自分の bundle ID）とペインの `ORBE_BUNDLE_ID` を突き合わせ、食い違えば no-op。dev / release の plugin は別枠として両方 enabled になり、CLI は有効な全 plugin の hook を全セッションで走らせるため。判定材料が片方でも欠けたら通す——状態追跡を黙って殺さない。stamp をシムの隣に置くのは、agy がプラグイン本体 subdir だけをステージするため。

## event→state 対応

- **claude**: SessionStart→idle / UserPromptSubmit→working / Notification(permission_prompt|worker_permission_prompt)→waiting / PreToolUse(AskUserQuestion|ExitPlanMode)→waiting / PostToolUse(AskUserQuestion|ExitPlanMode)→working / PostToolBatch→working / Stop→done / SessionEnd→clear。Notification は matcher で permission 待ちの notification_type に絞る——絞らないと idle（無操作）等でも発火し waiting を誤認するため（matcher に外れた通知はフックコマンド自体が走らない）。待ちの解除は種類ごとに経路が分かれる——ツールの待ち（AskUserQuestion / ExitPlanMode）は待つツールが事前に確定するので同じ matcher の PostToolUse が応答の瞬間に解除し（matcher 無しにすると並列に走る無関係なツールの完了でも撃たれ waiting が潰れる）、permission の待ちはどのツールが承認されるか事前に分からないのでバッチ解決（PostToolBatch・matcher の概念を持たないイベント）で解除する。
- **codex**: UserPromptSubmit→working / PermissionRequest→waiting / Stop→done
- **agy**: PreInvocation→working / Stop→done（agy のフックに SessionStart/Notification/PermissionRequest 相当が無く idle/waiting/clear は取得不可）

## `.app` 同梱と実体化

`build-app.sh` が `app/agent-plugin/` と状態報告 CLI `orbe-report` をバンドルへ同梱する（実行ビット保持・binary は app 署名対象）。シムはこの binary を env 越しに `exec` する。

Orbe は**起動ごとに**同梱パッケージを **`ORBE_STATE_DIR` 非依存の安定パス**（Application Support 配下。bundle id 由来なのでチャネルごとに別——[channel](../platform/channel.md)。テスト用に実体化先を差し替える seam を持つ）へ実体化する（tmp へコピー→原子的差し替え＝冪等・途中失敗でも既存を壊さない・実行ビット保持）。毎起動やり直すのは、claude が登録先ディレクトリをライブ参照するため——同梱が更新されても実体化が走らなければ古い定義が読まれ続ける。安定パスを使うのは `marketplace add` が記録する登録先が消えて dangling しないため（隔離インスタンス起動でも同一パスを登録し、`.app` を消しても manifest は読める）。同一チャネルの隔離インスタンスは安定パスを共有するので、**中身は最後に起動したビルドのものになる**。実体化のとき自分の bundle ID を `hooks/channel` へ刻む。

登録は**名前が変わったときだけ**やり直す: 最後に登録できたプラグイン名を覚え、現在のチャネルの名前と違えば `install.sh` を無音でバックグラウンド実行する（[persistence](../platform/persistence.md)）。1 つでも CLI が失敗したら名前を記録せず、次回起動で再試行する。登録先パスは変わらないので、claude は内容の更新だけなら登録し直す必要がない（codex / agy は自分のコピーを読むため、内容が変わっても再導入するまで届かない）。

## 初回オンボーディング

Orbe は初回起動時にオンボーディング overlay を出す（scrim クリックでは閉じない）。検出未完了の間はスピナーを見せて確定を止め、完了で検出 CLI を見せてデフォルトエージェントを選ばせ（↑↓選択・⌘↑↓ で先頭/末尾へジャンプ・行はホバーで選択が追従し、行タップは「始める」と同じ確定〔検出中は不発〕）、「始める」で**起動時に実体化済みの安定パス**を引数に `install.sh` をログインシェル PATH 付きでバックグラウンド実行する。per-CLI のライブ進捗（待機/導入中/完了/失敗/スキップ〔未検出 CLI〕）を表示する。

**1 つ以上導入できて 1 つも失敗しなければ**導入済みの記録と登録できた名前を残して閉じ、そうでなければ何も残さず閉じて次回起動で再表示する——検出 CLI が全てスキップに落ちた完了も「導入できていない」側に置く（記録すると名前が一致するので二度と再試行されず、状態追跡が無音のまま止まる）。検出ゼロでの「始める」は導入を走らせず、何も記録せずに閉じる。`install.sh` は各 CLI を検出し開始時・完了時に 1 行ずつ状態を出力（Orbe が行ストリームで読む・出力は全行が届いてから完了を報せる）、冪等導入し、ハングはタイムアウトで打ち切る。`.app` 同梱が無い（`swift run`）か既に導入できていればオンボーディングは出ない。
