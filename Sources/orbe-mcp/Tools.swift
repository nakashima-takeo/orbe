import Foundation

// MCP に露出するツール定義（名前＝control のメソッド名）。description は AI が読む唯一の説明なので、
// 使い分け（prompt_agent と send_text）・意味（ready:false・truncated）・導出手順（session_log →
// restore_sessions）をここに持つ。main.swift（stdio ループ・control 転送）から分離し、ツールを足す
// ときに触るのはこのファイルだけにする。

func obj(_ pairs: [(String, Any)]) -> [String: Any] { Dictionary(uniqueKeysWithValues: pairs) }
func strProp(_ desc: String) -> [String: Any] { ["type": "string", "description": desc] }
func intProp(_ desc: String) -> [String: Any] { ["type": "integer", "description": desc] }
func boolProp(_ desc: String) -> [String: Any] { ["type": "boolean", "description": desc] }
func strArrayProp(_ desc: String) -> [String: Any] {
  ["type": "array", "items": ["type": "string"], "description": desc]
}

func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
  ["type": "object", "properties": props, "required": required]
}

let tools: [[String: Any]] = [
  obj([
    ("name", "list_workspaces"),
    (
      "description",
      "Orbe の全 workspace を列挙する（id・名前・root path・タブ数・アクティブか・休眠 agent 数 dormantAgentCount）。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "list_tabs"),
    (
      "description",
      "全タブを列挙する。tabId（操作の宛先）・所属 workspace・タイトル・cwd・エージェント状態・その workspace で選択中か（active）を返す。"
        + "応答の seq はこの時点のイベント履歴位置（他の成功応答も同じく seq を持つ）。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "list_agents"),
    (
      "description",
      "検出済みのエージェント CLI（claude / codex / agy）を列挙する。各要素は command と解決済み絶対 path。"
        + "spawn_agent の command に渡す候補源。検出未完了なら空配列を返す。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "get_tab_text"),
    ("description", "タブの画面テキストを平文で取得する。scrollback=true で履歴全体、false で可視範囲のみ。"),
    (
      "inputSchema",
      schema(
        ["tabId": intProp("対象タブ ID"), "scrollback": boolProp("履歴全体を含めるか（既定 false）")],
        required: ["tabId"])
    ),
  ]),
  obj([
    ("name", "send_text"),
    (
      "description",
      "タブへテキストをペースト相当で送る（生の入力）。bracketed paste 下では改行を含めても"
        + "自己実行せずプロンプトに留まる。コマンドを実行するには送信後に send_key で enter を送る。"
        + "エージェントに問うなら prompt_agent を使う。応答の seq はこの送信以前の履歴位置で、"
        + "wait_for_event の after に渡せる。"
    ),
    (
      "inputSchema",
      schema(
        ["tabId": intProp("対象タブ ID"), "text": strProp("送るテキスト")],
        required: ["tabId", "text"])
    ),
  ]),
  obj([
    ("name", "send_key"),
    (
      "description",
      "タブへキーを送る。名前付きキー: enter / return / tab / escape / esc / space / backspace / "
        + "delete / up / down / left / right / home / end / pageup / pagedown。単一の Unicode 文字"
        + "（制御文字と '+' は不可）にも ctrl / alt / shift を付けられる（'ctrl+c' / 'ctrl+l' / "
        + "'alt+b'）。shift は大文字化（'shift+a' は A）。cmd は名前付きキーにだけ付けられる"
        + "（単一文字に付けると拒否）。修飾付きキーは端末自身の keybind に先に消費され、タブへ届かない"
        + "ことがある。"
    ),
    (
      "inputSchema",
      schema(
        ["tabId": intProp("対象タブ ID"), "key": strProp("キー名（修飾は + 連結。例 'ctrl+c'）")],
        required: ["tabId", "key"])
    ),
  ]),
  obj([
    ("name", "spawn"),
    ("description", "新しいタブを開く。command 省略時はシェル、指定時はそのコマンドを直接起動。戻り値は新タブ ID（tabId）。"),
    (
      "inputSchema",
      schema([
        "workspaceId": intProp("開く workspace（省略時アクティブ）"),
        "cwd": strProp("作業ディレクトリ（省略時アクティブタブ由来）"),
        "command": strProp("シェルの代わりに起動するコマンド（絶対パス推奨）"),
      ])
    ),
  ]),
  obj([
    ("name", "spawn_agent"),
    (
      "description",
      "検出済みエージェントを新タブで起こす。GUI の起動と同じ経路（解決済み絶対パス・login shell の PATH 注入）"
        + "を通るので、シェルの PATH に依存する子プロセスも動く。command 省略時は対象 workspace の実効デフォルト。"
        + "workspaceId を指定してもその workspace は**前面化しない**（手元の画面は動かない）。"
        + "戻り値は tabId / workspaceId / agent{command,path} / ready / seq。idle を報告できる"
        + "agent（claude）は準備できた（最初の idle）まで待ち ready:true と agentSessionId（実 session ID）を"
        + "返すので、続けて prompt_agent を送れる。ready:false は prompt を送れる保証が無い——codex / agy は"
        + "idle を報告できず即返り、時間切れ（timedOut:true）はタブは開いたが報告がまだ来ていない。"
    ),
    (
      "inputSchema",
      schema([
        "command": strProp("起動する agent（list_agents の command。省略時は対象 WS の実効デフォルト）"),
        "workspaceId": intProp("開く workspace（省略時アクティブ。未知 id はエラー）"),
        "cwd": strProp("作業ディレクトリ（省略時は対象 WS のアクティブタブ由来）"),
        "timeoutMs": intProp("準備完了を待つ上限 ミリ秒（既定 30000）"),
      ])
    ),
  ]),
  obj([
    ("name", "resume_agent"),
    (
      "description",
      "既存セッションを再開する形でエージェントを新タブで起こす（claude --resume / codex resume / agy --conversation）。"
        + "起動経路・戻り値（ready / agentSessionId / timeoutMs の意味）は spawn_agent と同じで、"
        + "対象 workspace は前面化しない。sessionId の出所は spawn_agent の agentSessionId か "
        + "list_tabs の agentSessionId。"
    ),
    (
      "inputSchema",
      schema(
        [
          "command": strProp("再開する agent（claude / codex / agy）"),
          "sessionId": strProp("再開するセッション ID"),
          "workspaceId": intProp("開く workspace（省略時アクティブ。未知 id はエラー）"),
          "cwd": strProp("作業ディレクトリ（省略時は対象 WS のアクティブタブ由来）"),
          "timeoutMs": intProp("準備完了を待つ上限 ミリ秒（既定 30000）"),
        ], required: ["command", "sessionId"])
    ),
  ]),
  obj([
    ("name", "activate_workspace"),
    (
      "description",
      "休眠/背景 workspace をアクティブ化して全タブを mount する。戻り値は activeWorkspaceId と mount された"
        + "タブの tabId 群。0タブ WS は空状態を表示（シェルは自動起動せず tabIds は空配列）。既にアクティブなら no-op で成功。"
    ),
    (
      "inputSchema",
      schema(["workspaceId": intProp("アクティブにする workspace の id")], required: ["workspaceId"])
    ),
  ]),
  obj([
    ("name", "session_log"),
    (
      "description",
      "エージェントセッションの寿命ログ（event=opened / closed）を時刻昇順で返す。各行は ts・workspace"
        + "{name,rootPath}・cwd・agent{command,sessionId}、closed は origin（agent / gesture / process / "
        + "controlAPI / unresolved）と任意の reason・title（閉じた時点のタブ表示名）を持つ。閉じたまま"
        + "戻っていないものは、sessionId ごとに"
        + "最後のイベントが event=closed で、かつ list_tabs の agentSessionId に居ない id。同時刻に "
        + "origin=process で閉じた群（5 秒以内）が事故の署名。復元は restore_sessions。limit 既定 1000"
        + "（上限 10000。超えた分は古い側が落ち truncated=true）。"
    ),
    (
      "inputSchema",
      schema([
        "since": strProp("この時刻以降（ISO 8601。例 2026-09-06T10:32:37Z）"),
        "until": strProp("この時刻以前（ISO 8601）"),
        "limit": intProp("返す件数の上限（既定 1000・上限 10000。超えた分は古い側が落ちる）"),
        "sessionId": strProp("この sessionId のイベントだけ"),
      ])
    ),
  ]),
  obj([
    ("name", "restore_sessions"),
    (
      "description",
      "閉じたセッションを休眠チケットとして該当 workspace（rootPath 一致。無ければログの名前で作る）へ"
        + "戻す（位置は新規タブと同じ規則＝同じ worktree の連の右端、無ければ末尾）。resume_agent と違い起動しない——選択も前面化もせず、タブが mount されたとき resume で"
        + "起きる（アクティブ workspace に戻した分は次にいずれかのタブを選んだとき他の未 mount タブと順次、"
        + "背景 workspace の分はその workspace のアクティブ化で）。復元先が背景 workspace のとき、話しかける"
        + "には先に focus_tab / activate_workspace で起こす（起こす前の prompt_agent は tab not mounted）。"
        + "結果は id ごとに restored / "
        + "already-present / unknown（部分成功も成功・冪等）。多数を一度に戻すときはこのツール"
        + "（または orb session restore）を使う——Orbe の ⇧⌘T パレットは 1 件ずつしか戻さない。"
    ),
    (
      "inputSchema",
      schema(
        ["sessionIds": strArrayProp("戻す sessionId の列挙（1〜100 件。session_log の agent.sessionId）")],
        required: ["sessionIds"])
    ),
  ]),
  obj([
    ("name", "prompt_agent"),
    (
      "description",
      "タブのエージェントに text を送って enter を押し、エージェントが止まるまで待つ。"
        + "戻り値は state（done=応答を終えた / waiting=質問か承認を求めている / clear=セッションが終わった）・"
        + "message（その時点の文言。done なら最終応答、waiting なら質問文。無ければキー欠落）・seq。"
        + "送信直後に済んだ遷移も取りこぼさない。エージェントに問う用途はこれを使い、send_text＋send_key は"
        + "生の入力（waiting への応答・シェルコマンド）に、wait_for_event は特殊な待ちにだけ使う。"
        + "対象が working / waiting を報告していれば何も送らずエラー（waiting への応答は send_key で）。"
        + "判定は hook 報告だけなので、拒めるのは waiting を報告する agent（claude / codex、プラグイン"
        + "導入済み）に限る——報告経路の無いタブでは承認ダイアログが開いていても送られ、既定選択が確定する。"
        + "タイムアウトは timedOut:true（既定 3600000 ms＝1 時間。MCP クライアント側のツール"
        + "タイムアウトがそれより短いことがあるので timeoutMs を明示するとよい）。"
    ),
    (
      "inputSchema",
      schema(
        [
          "tabId": intProp("対象タブ ID（spawn_agent の tabId）"),
          "text": strProp("送るテキスト（改行を含んでよい）"),
          "timeoutMs": intProp("エージェントが止まるまで待つ上限 ミリ秒（既定 3600000・上限 86400000）"),
        ], required: ["tabId", "text"])
    ),
  ]),
  obj([
    ("name", "wait_for_event"),
    (
      "description",
      "状態変化イベントを待つ（長ポーリング）。扱える kind: agent_state / title / pwd / "
        + "tab_closed（libghostty が host に出す OSC シグナル）。生のシェル出力は待てない"
        + "（その用途は get_tab_text をポーリング）。エージェントの応答を待つなら prompt_agent を使う。"
        + "全イベントに 1 本の単調増加 seq が付く。after を渡すと、その seq より後に既に起きた一致イベントも"
        + "即返す（after の出所は他の応答の seq）。after が保持範囲より古ければ event history evicted の"
        + "エラー（seq を取り直す）。"
        + "タイムアウトすると timedOut:true を返す。未知の kind と不正な timeoutMs / after / value は"
        + "エラーで弾かれる（黙って時間切れにはならない）。"
    ),
    (
      "inputSchema",
      schema([
        "tabId": intProp("このタブのイベントだけ待つ（省略時は全タブ）"),
        "kinds": [
          "type": "array", "items": ["type": "string"],
          "description": "待つ kind の集合（省略時は全種）",
        ],
        "value": strProp("kind 固有値の完全一致（agent_state なら状態語。省略時は問わない）"),
        "after": intProp("この seq より後のイベントを対象にする（既に起きていれば即返す。0 可）"),
        "timeoutMs": intProp("タイムアウト ミリ秒（既定 30000）"),
      ])
    ),
  ]),
]

let toolNames = Set(tools.compactMap { $0["name"] as? String })
