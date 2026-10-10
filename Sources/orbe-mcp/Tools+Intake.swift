import Foundation

// 受信の 6 動詞の MCP ツール定義。秘書の AI が受信を作り・直し・結果を読むための説明をここに持つ。
// 提案をタスクにする・捨てるは人の判断なので、AI には出さない。

let intakeTools: [[String: Any]] = [
  obj([
    ("name", "list_intakes"),
    (
      "description",
      "タスクの自動追加（外の出どころから項目を定期的に取り、判定の agent にタスクにすべきものを候補として出させる仕組み）を ID 順に返す。"
        + "各要素は intakeId と set_intake と同じ定義（name・fetch・judge・when）に加え、paused（予定を止めているか）・"
        + "running（回が走っているか）・nextRunAt（次に予定で回る時刻。止めていれば無い）・lastRunAt・"
        + "openProposals（この自動追加の棚に出ている候補の数）・overlaps（前回の取得結果が他の自動追加と重なっているリンクの数 "
        + "[{intakeId, name, count}]。範囲の切り直しの手がかり）・runs（回の記録。新しい順に 20 件まで。"
        + "各回は startedAt・endedAt・trigger（schedule / now）・fetch{commandLine, ending, items, rejected{count, reasons}}・"
        + "newItems（判定に回した数）・judge{commandLine, ending, proposed, resolved, rejected}（判定を起こさなかった回は無い）・"
        + "withdrawn（取得結果から消えて下げた候補の数）・failure（失敗した回の理由）。"
        + "失敗した回は取得済みも候補も動かさないので、failure と rejected.reasons を読んで取得や指示文を直す。"
    ),
    ("inputSchema", schema([:])),
  ]),
  obj([
    ("name", "set_intake"),
    (
      "description",
      "タスクの自動追加を作るか、intakeId を渡して丸ごと置き換え、その自動追加を返す。name・fetch・judge・when の 4 つが全部必須。"
        + "name は「出どころ: 何を取るか」の 1 行（例「Slack: 自分宛の DM・メンション」）。"
        + "範囲は fetch の条件（検索語・期間・宛先）で切る。広すぎる取得は判定の依頼文を大きくし、失敗の元になる。"
        + "fetch はコマンド {command, directory?, coverage}（/bin/sh -c で走る。directory は絶対パス、既定はホーム）か、"
        + "軽い agent {agent?（既定 claude）, model, tools（使ってよい MCP のツールの完全名 mcp__<サーバー>__<ツール> を 1 つ以上）, "
        + "request（何を取るか）, coverage}。取得役は外から届いた文面を読むので、組み込みのツール・サーバー単位（mcp__<サーバー>）・"
        + "ワイルドカードは断られる（文面に仕込まれた指示で書き込みが起きないように）。"
        + "名前の形は検証されても読み取りかどうかは検証されないので、tools には出どころを読むツールだけを名指しする"
        + "（送信・更新・削除などの書き込みのツールや、Orbe 自身のツールは渡さない）。"
        + "coverage は取得の性質で必須。\"currentSet\"（取得結果がその時点の全体。例: 自分が担当の未完了課題・"
        + "自分へのレビュー依頼）は、取得から消えた項目の候補を Orbe が下げる。\"newArrivals\"（取得結果は新着だけ。"
        + "例: 自分宛の新しい DM・メンション）は、取得から消えても下げず、判定が対応済みとしたときだけ下げる"
        + "（判定には、この自動追加が出して人の判断待ちの候補も見せる）。"
        + "コマンドは 1 項目 1 行の JSON {\"id\": 出どころの中で変わらない ID, \"link\": http(s) の URL, \"body\": 本文, "
        + "\"time\": ISO 8601 の時刻} だけを標準出力に出し、取得に失敗したら終了コードを 0 以外にするか "
        + "{\"error\": 理由} の 1 行だけを出す。agent の取得役には Orbe が同じ出力の形を指示する。"
        + "judge は {agent?（既定 claude）, model, instruction}。指示文は「どんな項目をタスクにするか・タイトルと期限の付け方」"
        + "を書く。判定の agent はツールを持たず、Orbe が渡す新しい項目だけを読み、出力の形は Orbe が決める。"
        + "when は {everyMinutes: 1〜10080（7 日）} か {dailyAt: [\"09:00\", \"13:00\"]}。"
        + "前の回に無かった項目だけが判定に回り、新しい項目が無い回は判定を起こさない。"
        + "候補はリンク単位ですべての自動追加を通じて 1 つ。"
        + "置き換えで fetch のやり方（coverage 以外）か judge が変わると、走っている回を止め、次の回は取れた全件を"
        + "新しい判定で見直す（既に候補のあるリンクは見直さない）。name・when・coverage だけの置き換えは走っている回を"
        + "止めない。"
        + "新しく作った自動追加はすぐには回らない。試すときは run_intake。"
    ),
    (
      "inputSchema",
      schema(
        [
          "intakeId": intProp("置き換える自動追加（省略で新規）"),
          "name": strProp("「出どころ: 何を取るか」の 1 行"),
          "fetch": [
            "type": "object",
            "description":
              "コマンド {command, directory?, coverage} か agent {agent?, model, tools, request, coverage}。"
              + "coverage は \"currentSet\" か \"newArrivals\"",
          ],
          "judge": [
            "type": "object", "description": "{agent?（既定 claude）, model, instruction}",
          ],
          "when": [
            "type": "object", "description": "{everyMinutes: n} か {dailyAt: [\"HH:MM\", …]}",
          ],
        ], required: ["name", "fetch", "judge", "when"])
    ),
  ]),
  obj([
    ("name", "run_intake"),
    (
      "description",
      "タスクの自動追加を今すぐ 1 回回す。すぐ返り、結果は list_intakes の runs に載る。止めた自動追加も回せる（有効にする前の試し打ち）。"
        + "回が走っている間は断られる（running を見る）。"
    ),
    ("inputSchema", schema(["intakeId": intProp("回す自動追加")], required: ["intakeId"])),
  ]),
  obj([
    ("name", "pause_intake"),
    (
      "description",
      "タスクの自動追加の予定を止める（paused: true）・再開する（false）。止めるのは予定だけで、走っている回は最後まで走り、"
        + "run_intake は受ける。止めた自動追加の取得結果も覚えているので、候補は下がらない。"
    ),
    (
      "inputSchema",
      schema(
        ["intakeId": intProp("対象の自動追加"), "paused": boolProp("true で止める、false で再開")],
        required: ["intakeId", "paused"])
    ),
  ]),
  obj([
    ("name", "delete_intake"),
    (
      "description",
      "タスクの自動追加を消す。走っている回は止め、その結果は捨てる。この自動追加だけが取っていたリンクの候補は忘れられる。"
    ),
    ("inputSchema", schema(["intakeId": intProp("消す自動追加")], required: ["intakeId"])),
  ]),
  obj([
    ("name", "list_intake_proposals"),
    (
      "description",
      "タスクの自動追加の判定が出した候補を、覚えている全状態で返す（指示文を直す材料）。各要素は proposalId・state"
        + "（open: 人の判断待ち / accepted: タスクにした〔taskId〕 / dismissed: 捨てた / resolved: 判定が対応済みとした）・"
        + "title・due（YYYY-MM-DD）・link・body・time・proposedAt・intakeId と intakeName（棚に出す自動追加）。"
        + "intakeId を渡すとその自動追加の棚の分だけ。候補をタスクにする・捨てるのは人が Orbe の画面で行う。"
    ),
    ("inputSchema", schema(["intakeId": intProp("この自動追加の棚の候補だけに絞る")])),
  ]),
]
