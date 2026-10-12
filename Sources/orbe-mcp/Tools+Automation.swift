import Foundation

// 自動化の 6 動詞の MCP ツール定義。秘書の AI が自動化を作り・直し・結果を読むための説明をここに持つ。
// 候補をタスクにする・捨てるは人の判断なので、AI には出さない。

private let definitionShape =
  "定義は {name, trigger, source?, steps, sink}。自動化は、トリガー → 取得元（任意）→ 処理の段 0 個以上 → 出力先 の順に流れる。"
  + "今ある出力先はタスク候補 {\"kind\": \"taskCandidates\"} だけで、取得元（coverage は currentSet か newArrivals）と段 1 つ以上が要る。"
  + "name は「出どころ: 何を取るか」の 1 行（例「GitHub: 自分へのレビュー依頼」）。"
  + "trigger は {everyMinutes: 1〜10080（7 日）} か {dailyAt: [\"09:00\", \"13:00\"]}。"
  + "source はコマンド {command, directory?, coverage}（/bin/sh -c で走る。directory は絶対パス、既定はホーム）か、"
  + "軽い agent {agent?（既定 claude）, model?, tools（使ってよい MCP のツールの完全名 mcp__<サーバー>__<ツール> を 1 つ以上）, "
  + "request（何を取るか）, coverage}。範囲は取得の条件（検索語・期間・宛先）で切る。広すぎる取得は段の依頼文を大きくし、失敗の元になる。"
  + "取得元の agent は外から届いた文面を読むので、組み込みのツール・サーバー単位（mcp__<サーバー>）・ワイルドカードは断られる"
  + "（文面に仕込まれた指示で書き込みが起きないように）。名前の形は検証されても読み取りかどうかは検証されないので、"
  + "tools には出どころを読むツールだけを名指しする（送信・更新・削除などの書き込みのツールや、Orbe 自身のツールは渡さない）。"
  + "取得元のコマンドは 1 項目 1 行の JSON {\"id\": 出どころの中で変わらない ID, \"link\": http(s) の URL, \"body\": 本文, "
  + "\"time\": ISO 8601 の時刻} だけを標準出力に出し、取得に失敗したら終了コードを 0 以外にするか {\"error\": 理由} の 1 行だけを出す。"
  + "agent の取得元には Orbe が同じ出力の形を指示する。"
  + "coverage は取得の性質で必須。\"currentSet\"（取得結果がその時点の全体。例: 自分が担当の未完了課題・自分へのレビュー依頼）は、"
  + "取得から消えた項目の候補を Orbe が下げる。\"newArrivals\"（取得結果は新着だけ。例: 自分宛の新しい DM・メンション）は、"
  + "取得から消えても下げず、最後の段が対応済みとしたときだけ下げる。\"everything\" は前回の取得結果との差分を掛けない（タスク候補では使えない）。"
  + "newArrivals では、前回成功した回の開始時刻が、コマンドには環境変数 ORBE_SINCE（ISO 8601、UTC）で、agent には依頼文の 1 文で渡る。"
  + "その時刻以降を取ればよく、前の分が混ざってもよい（Orbe が id で除く）。初回は渡らない。"
  + "steps は段の並び。段は {name, command, directory?} か {name, agent?（既定 claude）, model?, instruction} で、"
  + "JSON の行を受けて JSON の行を出す（コマンドの段には標準入力で、agent の段には Orbe の枠の依頼文で渡る）。"
  + "段の agent はツールを持たない（tools は書けない）。項目は取得元の id でたどるので、段は渡された id を保つ。"
  + "最後の段に届いた行の id が全部外れた回は失敗になる。安い段（コマンド・haiku）で先に絞ってから、高い段に回す。"
  + "model を省略すると、最後の段は sonnet、それ以外の段と取得元は haiku で走る。省略は省略のまま保存され、段を並べ替えれば既定も追従する。"
  + "出力先がタスク候補のとき、最後の段が agent なら Orbe が出力の形（propose / resolve）を指示するので、指示文には"
  + "「どんな項目をタスクにするか・タイトルと期限の付け方」を書く。最後の段がコマンドなら、自分で "
  + "{\"propose\": id, \"title\": …, \"due\"?: \"YYYY-MM-DD\"} の行を出す（判断待ちの候補は渡らないので resolve は出せない）。"
  + "前の回に無かった項目だけが段に回り、新しい項目が無い回は段を起こさない。候補はリンク単位ですべての自動化を通じて 1 つ。"
  + "例: {\"name\": \"GitHub: 自分へのレビュー依頼\", \"trigger\": {\"everyMinutes\": 30}, "
  + "\"source\": {\"command\": \"gh api …\", \"coverage\": \"currentSet\"}, "
  + "\"steps\": [{\"name\": \"絞り込み\", \"command\": \"jq -c 'select(…)'\"}, "
  + "{\"name\": \"判定\", \"instruction\": \"…\"}], \"sink\": {\"kind\": \"taskCandidates\"}}。"

let automationTools: [[String: Any]] = [
  obj([
    ("name", "list_automations"),
    (
      "description",
      "自動化（外の出どころから項目を予定どおり取り、処理の段で絞り・判断して、出力先へ出す仕組み）を ID 順に返す {automations}。"
        + "各要素は automationId・definition（set_automation と同じ定義を保存のまま。省略したものは省略のまま）・"
        + "paused（予定を止めているか）・running（回が走っているか）・nextRunAt（次に予定で回る時刻。止めていれば無い）・lastRunAt・"
        + "runs（回の記録）。出力先がタスク候補の自動化だけが taskCandidates {openProposals"
        + "（この自動化の棚に出ている候補の数）, overlaps（前回の取得結果が他の自動化と重なっているリンクの数 "
        + "[{automationId, name, count}]。範囲の切り直しの手がかり）} を持つ。"
        + "runs は新しい順に 20 件まで。各回は startedAt・endedAt・trigger（schedule / now）・"
        + "source{commandLine, ending, count, rejected{count, reasons}}"
        + "（取得元の無い自動化と、取得元まで行かなかった回は無い）・fresh（段に回した新しい項目の数）・"
        + "steps[{name, commandLine, ending, count, rejected}]（走った段だけ）・"
        + "sink{kind, proposed, resolved, withdrawn, rejected}（確定した回だけ。withdrawn は下げた候補の数）・failure（失敗した回の理由）。"
        + "count は取得元なら項目として読めた数、段なら JSON の行として読めた数で、rejected は読めなかった行。"
        + "失敗した回は取得済みも候補も動かさないので、failure と各所の rejected.reasons を読んで、どこで落ちたかを直す。"
        + "モデルを省略した段は、最後の段なら sonnet、それ以外の段と取得元なら haiku で走る。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "set_automation"),
    (
      "description",
      "自動化を作るか、automationId を渡して定義を丸ごと置き換え、その自動化を list_automations の 1 要素の形で返す {automation}。"
        + definitionShape
        + "書き直すときは、list_automations の definition を取り、直して丸ごと送る。"
        + "置き換えで、取得元のやり方・段の手段とモデル（省略は解いた値で比べる）と指示文かコマンド・出力先が変わると、"
        + "走っている回を止め、次の回は取れた全件を見直す（既に候補のあるリンクは見直さない）。"
        + "名前・トリガー・coverage・段の名前だけの置き換えは走っている回を止めない。"
        + "新しく作った自動化はすぐには回らない。試すときは run_automation。"
    ),
    (
      "inputSchema",
      schema(
        [
          "automationId": intProp("置き換える自動化（省略で新規）"),
          "definition": [
            "type": "object",
            "description":
              "{name, trigger, source?, steps, sink}。trigger は {everyMinutes: n} か {dailyAt: [\"HH:MM\", …]}、"
              + "source は {command, directory?, coverage} か {agent?, model?, tools, request, coverage}、"
              + "steps は [{name, command, directory?} か {name, agent?, model?, instruction}]、"
              + "sink は {\"kind\": \"taskCandidates\"}",
          ],
        ], required: ["definition"])
    ),
  ]),
  obj([
    ("name", "run_automation"),
    (
      "description",
      "自動化を今すぐ 1 回回す。すぐ返り、結果は list_automations の runs に載る。止めた自動化も回せる（有効にする前の試し打ち）。"
        + "回が走っている間は断られる（running を見る）。"
    ),
    ("inputSchema", schema(["automationId": intProp("回す自動化")], required: ["automationId"])),
  ]),
  obj([
    ("name", "pause_automation"),
    (
      "description",
      "自動化の予定を止める（paused: true）・再開する（false）。止めるのは予定だけで、走っている回は最後まで走り、"
        + "run_automation は受ける。止めた自動化の取得結果も覚えているので、候補は下がらない。"
    ),
    (
      "inputSchema",
      schema(
        ["automationId": intProp("対象の自動化"), "paused": boolProp("true で止める、false で再開")],
        required: ["automationId", "paused"])
    ),
  ]),
  obj([
    ("name", "delete_automation"),
    (
      "description",
      "自動化を消す。走っている回は止め、その結果は捨てる。この自動化だけが取っていたリンクの候補は忘れられる。"
    ),
    ("inputSchema", schema(["automationId": intProp("消す自動化")], required: ["automationId"])),
  ]),
  obj([
    ("name", "list_automation_proposals"),
    (
      "description",
      "出力先がタスク候補の自動化が出した候補を、覚えている全状態で返す（指示文を直す材料）。各要素は proposalId・state"
        + "（open: 人の判断待ち / accepted: タスクにした〔taskId〕 / dismissed: 捨てた / resolved: 最後の段が対応済みとした）・"
        + "title・due（YYYY-MM-DD）・link・body・time・proposedAt・automationId と automationName（棚に出す自動化）。"
        + "automationId を渡すとその自動化の棚の分だけ。候補をタスクにする・捨てるのは人が Orbe の画面で行う。"
    ),
    ("inputSchema", schema(["automationId": intProp("この自動化の棚の候補だけに絞る")])),
  ]),
]
