---
title: エージェントプラグイン（配布物）
description: claude / codex / agy 兼用プラグインパッケージ app/agent-plugin/ の構造・各 CLI の導入契約・チャネル別のプラグイン名・MCP サーバー・.app 同梱と毎起動の実体化・中身の指紋による入れ直し
updated: 2026-10-10
---

# エージェントプラグイン（配布物）

`app/agent-plugin/` は claude / codex / agy を 1 ディレクトリで兼ねるプラグインパッケージ。2 つのものを各 CLI へ届ける。1 つは状態追跡の hook で、Orbe の状態報告シムを呼び、[notify](notify.md) の制御ソケット経路に乗せる。もう 1 つは MCP サーバーで、Orbe のタブで起こした agent に Orbe の MCP ツール（[api](../control/api.md) の MCP ブリッジ）を出す。利用者は何も設定しない。プラグインには binary を入れず純テキストのまま保つ（シムが `.app` 同梱の `orbe-report` / `orbe-mcp` を env パスで指す）。プラグイン本体は `plugins/<プラグイン名>/` に 1 箇所だけ置き（スクリプト重複なし）、claude/codex の marketplace 定義をルートからそこへ向ける。パッケージルートには各 CLI の marketplace 定義と、各 CLI へ冪等導入する `install.sh` を置く。

## チャネル別のプラグイン名

**プラグイン名（＝marketplace 名＝`plugins/` 直下のディレクトリ名）はチャネルごとに別**で、1 つの名前がパッケージの全出現箇所（両 marketplace 定義の name と source・3 つの plugin 定義の name・agy hooks のトップキー・3 つの MCP 定義のサーバー名・ディレクトリ名）を通る（[channel](../platform/channel.md)）。**agy は marketplace を持たず plugin 名だけで枠が分かれる**ため、marketplace 名だけ分けても 3 CLI が揃って分かれない。

## 各 CLI の marketplace/導入契約

実機で確定した契約（「marketplace add 成功」≠「plugin install 成功」）。

- **claude**: ルートの `.claude-plugin/marketplace.json` を読む。`plugin marketplace add <dir>` ＋ `plugin install`。**登録先をライブ参照する**ので、登録後に中身を書き換えれば次のセッションから新しい定義が走る。
- **codex**: ルートの `.agents/plugins/marketplace.json` を読み、プラグインは `plugins/<name>/` サブディレクトリに置く規約（`source.path` がルート自身だと取り込まれない）。`plugin marketplace add <dir>` ＋ `plugin add`。**導入時のキャッシュコピーを読む**ので、登録先を書き換えても再導入まで新しい定義は届かない（`plugin list` の PATH 列は登録先を表示するため見分けにくい）。
- **agy**: marketplace 不要。本体 subdir を直接指す `plugin install`。導入はステージ先へコピーされ、フック実行 cwd はこのステージ済みプラグインルートになる。**ステージ済みコピーを読む**ので、codex と同じく再導入まで新しい定義は届かない。

`install.sh` はプラグインディレクトリとプラグイン名を引数で受け、「渡したディレクトリの中身を、各 CLI が読むものにそろえる」。claude は登録先をライブ参照するので、未導入のときだけ導入する（導入済みなら unchanged）。codex と agy はコピーを読むので入れ直す。利用者がプラグインを無効にした設定は、どの CLI でも残す。

- codex は marketplace の追加（冪等）のあと `plugin add` し、キャッシュのコピーを丸ごと置き換える。`plugin add` は必ず有効へ戻すので、利用者が無効にしていれば入れ直さない（unchanged）。有効に戻したあとは、次に中身が変わるまで古いコピーのまま。
- agy は `plugin install` し直す。ステージ先は中身どおりに置き換わり（消したファイルも消える）、有効/無効の設定は残る。

自分の枠かどうか（claude の導入済み・codex の無効）は名前の**完全一致**で見る——前方一致だと別チャネルの枠を自分のものと誤認する（claude は `<name>@<name>`、codex は JSON 出力の plugin ID）。

hook からシムを呼ぶ経路も CLI ごとに違う: claude / codex はそれぞれのプラグインルート env 変数を展開して絶対パスで呼ぶ。agy は変数置換が効かないため相対パスで呼ぶ（cwd がステージ済みプラグインルートである契約に依存）。

## チャネル判定

状態追跡のシムと MCP のシムは、どちらも**自分と同じチャネルのタブからの呼び出しにだけ応える**。プラグインのルートの `channel`（実体化時に Orbe が刻む自分の bundle ID）とタブの `ORBE_BUNDLE_ID` を突き合わせ、食い違えば応えない（状態追跡は no-op、MCP は空サーバー）。dev / release の plugin は別枠として両方 enabled になり、CLI は有効な全 plugin の hook と MCP サーバーを全セッションで走らせるため。判定材料が片方でも欠けたら通す——状態追跡を黙って殺さない。刻印は 2 つのシムが共有する事実なので、片方の持ち物（`hooks/`）ではなくプラグインのルート（`plugins/<name>/` 直下）に置く。agy がステージするのはプラグイン本体の subdir だけだが、刻印はその中にあるので届く。

## MCP サーバー

プラグインは状態追跡の hook に加えて MCP サーバーを 1 つ持つ。**サーバー名はプラグイン名と同じ**（[channel](../platform/channel.md)）——codex はサーバー名がプラグインをまたいで共通なので、dev と release で分けないと片方しか起動しない。宣言は hooks と同じく各 CLI のマニフェストが自分の定義だけを指し、どれも `mcp/orbe-mcp.sh`（MCP シム）を起動する。

- **claude**: `.claude-plugin/plugin.json` の `mcpServers`。プラグインルート変数を展開した絶対パスで呼ぶ（相対パスでは起動に失敗する）。
- **codex**: `.codex-plugin/plugin.json` の `mcpServers`。cwd をプラグインルートにした相対パスで呼ぶ。codex は MCP サーバーへ親の環境のうち既定の数個（`HOME`・`PATH` など）と名指しされた変数しか渡さないので、シムとブリッジが読む変数（`ORBE_MCP_BIN`・`ORBE_BUNDLE_ID`・`ORBE_TAB`・`ORBE_SOCK`）を `env_vars` で名指しして通す。
- **agy**: プラグインのルートの `mcp_config.json`。相対パスで呼ぶ。

プラグインのルートに `.mcp.json`（claude も codex も既定の置き場として読む）は置かない。

MCP シムは、`ORBE_MCP_BIN` が実行可能でチャネル判定に通れば、タブの `.app` 同梱の `orbe-mcp` へ exec する。ブリッジはタブの env（`ORBE_SOCK`・`ORBE_TAB`）でそのタブの Orbe にだけつながり、呼び出し元のタブを名乗る。プラグインにバイナリを入れないのは、ブリッジのツール定義とつなぐ先の制御 API の版をそろえるため——実体化先や codex / agy のコピーは同じチャネルの別ビルドと共有され、古いまま残りうる。

それ以外（Orbe の外・別チャネルの Orbe のタブ・同梱の無い Orbe）では、シムは**ツール 0 個の空サーバー**（`mcp/empty-server.pl`）へ exec する。即終了させないのは、CLI がプラグインの MCP サーバーを全セッションで起こし、接続失敗を毎回警告するため。Orbe の外にはバイナリが無いので、空サーバーは macOS 標準の perl で書く。改行区切りの JSON-RPC を読み、initialize には tools を名乗らない capabilities で、tools/list には空の一覧で、ping には空で応え、それ以外の要求は method not found を返す。通知と読めない行には応えない。

## event→state 対応

- **claude**: SessionStart(startup|resume|clear|fork)→idle / UserPromptSubmit→working / Notification(permission_prompt|worker_permission_prompt)→waiting / PreToolUse(AskUserQuestion|ExitPlanMode)→waiting / PostToolUse(AskUserQuestion|ExitPlanMode)→working / PostToolBatch→working / Stop→done / StopFailure→done / SessionEnd→clear。SessionStart は matcher で会話が始まる・切り替わる source に絞る——compact も SessionStart を撃ち、自動 compact はターンの途中で走るので、絞らないと作業中の agent を idle と誤認する（[秘書](secretary.md)が作業中の秘書へ次の頼みを貼る）。StopFailure（API エラーで終わったターン。Stop の代わりに撃たれる）もターンの終わりとして done に写す——写さないと working が残り、秘書への溜めが止まる。Notification は matcher で permission 待ちの notification_type に絞る——絞らないと idle（無操作）等でも発火し waiting を誤認するため（matcher に外れた通知はフックコマンド自体が走らない）。待ちの解除は種類ごとに経路が分かれる——ツールの待ち（AskUserQuestion / ExitPlanMode）は待つツールが事前に確定するので同じ matcher の PostToolUse が応答の瞬間に解除し（matcher 無しにすると並列に走る無関係なツールの完了でも撃たれ waiting が潰れる）、permission の待ちはどのツールが承認されるか事前に分からないのでバッチ解決（PostToolBatch・matcher の概念を持たないイベント）で解除する。
- **codex**: UserPromptSubmit→working / PermissionRequest→waiting / Stop→done / Interrupt→idle。turn を中断（Esc）すると Stop は出ず Interrupt だけが出るので、これを受けないと中断後も working が残る。中断は人が目の前で止めた操作で応答を終えたのではないので、done（通知音が鳴る）でなく idle に写す。
- **agy**: PreInvocation→working / Stop→done（agy のフックに SessionStart/Notification/PermissionRequest 相当が無く idle/waiting/clear は取得不可）

## `.app` 同梱と実体化

`build-app.sh` が `app/agent-plugin/` と、状態報告 CLI `orbe-report`・MCP ブリッジ `orbe-mcp` をバンドルへ同梱する（実行ビット保持・binary は app 署名対象）。シムはこれらの binary を env 越しに `exec` する。

Orbe は**起動ごとに**同梱パッケージを **state フォルダの下の安定パス**（[persistence](../platform/persistence.md)。常用なら Application Support 配下で、bundle id 由来なのでチャネルごとに別——[channel](../platform/channel.md)。テスト用に実体化先を差し替える seam を持つ）へ実体化する（tmp へコピー→原子的差し替え＝冪等・途中失敗でも既存を壊さない・実行ビット保持）。毎起動やり直すのは、claude が登録先ディレクトリをライブ参照するため——同梱が更新されても実体化が走らなければ古い定義が読まれ続ける。安定パスを使うのは `marketplace add` が記録する登録先が消えて dangling しないため（`.app` を消しても manifest は読める）。実体化のとき自分の bundle ID をプラグインのルートの `channel` へ刻む。

**隔離インスタンス（`ORBE_STATE_DIR`）は実体化だけをし、各 CLI へ登録しない**（下の入れ直しも初回オンボーディングもしない）。実体化先は自分の state フォルダの下なので常用の実体化先と指紋には触れないが、登録は利用者の CLI の設定そのもの——claude の marketplace の登録先、codex / agy のコピー——を書き換え、検証のために起こした Orbe が利用者の agent の中身を差し替えてしまう。隔離インスタンスのタブの agent は、常用の Orbe が登録したプラグイン（hook・MCP のシム）で動き、シムが env 越しに exec する `orbe-report` / `orbe-mcp` は隔離インスタンスの `.app` のもの。

登録は**中身の指紋が変わったときだけ**やり直す: 最後に登録できた実体化済みパッケージの指紋（全ファイルの相対パスと中身から作る SHA-256）を覚え、今回実体化した中身の指紋と違えば `install.sh` を無音でバックグラウンド実行する。codex / agy は自分のコピーを読むので、入れ直さなければ中身の更新が届かない。名前も刻印もパッケージの中にあるので、チャネルの違いも指紋の違いに含まれる。1 つでも CLI が失敗したら指紋を記録せず、次回起動で再試行する。記録をまだ持たない利用者は、食い違いとして一度入れ直される。

指紋の記録は実体化先の隣に 1 つ置く（実体化先の中には置かない。毎起動の差し替えに巻き込まれるため）。

## 初回オンボーディング

Orbe は初回起動時にオンボーディング overlay を出す（scrim クリックでは閉じない）。検出未完了の間はスピナーを見せて確定を止め、完了で検出 CLI を見せてデフォルトエージェントを選ばせ（↑↓選択・⌘↑↓ で先頭/末尾へジャンプ・行はホバーで選択が追従し、行タップは「始める」と同じ確定〔検出中は不発〕）、「始める」で**起動時に実体化済みの安定パス**を引数に `install.sh` を子プロセス PATH（[shell-path](../platform/shell-path.md)）付きでバックグラウンド実行する。per-CLI のライブ進捗（待機/導入中/完了/失敗/スキップ〔未検出 CLI〕）を表示する。

**1 つ以上導入できて 1 つも失敗しなければ**導入済みの記録（[persistence](../platform/persistence.md)）と導入した中身の指紋を残して閉じ、そうでなければ何も残さず閉じて次回起動で再表示する——検出 CLI が全てスキップに落ちた完了も「導入できていない」側に置く（記録すると指紋が一致するので二度と再試行されず、状態追跡が無音のまま止まる）。検出ゼロでの「始める」は導入を走らせず、何も記録せずに閉じる。`install.sh` は各 CLI を検出し開始時・完了時に 1 行ずつ状態を出力（Orbe が行ストリームで読む・出力は全行が届いてから完了を報せる）、ハングはタイムアウトで打ち切る。隔離インスタンス・`.app` 同梱が無い（`swift run`）・既に導入できている、のどれかならオンボーディングは出ない。
