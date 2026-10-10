import Foundation

/// 待ちの条件を付ける・外す動詞（`set_wait_condition`）の MCP ツール定義。条件のコマンドは人の承認なしに裏で
/// 繰り返し走るので、帳簿の動詞（`add_task` / `update_task`）に同居させず専用の口にする——agent CLI のツール許可は
/// ツール単位なので、帳簿の動詞を「常に許可」しても任意のコマンドの実行までは許可されない。
let waitConditionTools: [[String: Any]] = [
  obj([
    ("name", "set_wait_condition"),
    (
      "description",
      "待っているタスクに、待ちが解ける条件を付ける（condition が null なら条件だけを外す。待ちは残る）。"
        + "このツールは任意のシェルコマンドを人の承認なしに裏で繰り返し実行させる口。Orbe は付けた直後に 1 回、以後は"
        + " everyMinutes ごとに command を `/bin/sh -c` で確かめ、終了コード 0 で待ちを外す。成功時は標準出力の 1 行目に"
        + "起きたことを短く書く（行に出る。全体は詳細に出る）。command は呼び出し元タブの作業ディレクトリ"
        + "（分からなければホーム）で走る。deadline は必須で、満たされなくても期限で必ず解ける。解けたら、人が ⌘T で"
        + "この会話を続きから再開し、起きたことが最初の入力として届く（会話が記録されるのは、呼び出し元タブの agent が"
        + "作業中のときだけ）。付け直すと確認の回数と記録は空から始まる。待っていないタスク・完了のタスクには付けられない"
        + "（先に update_task の waitingReason で待ちにする）。変えた後のタスクを返す。"
    ),
    (
      "inputSchema",
      schema(
        [
          "taskId": intProp("対象タスク（待っているもの）"),
          "condition": [
            "type": ["object", "null"],
            "description": "解ける条件（null で条件だけを外す）",
            "properties": [
              "description": strProp("何が起きたら解けるか（1 行。例「PR #214 にレビューが付いたら」）"),
              "command": strProp("確認のコマンド（終了コード 0 で解ける。成功時は標準出力の 1 行目に起きたことを書く）"),
              "everyMinutes": intProp("確認の間隔（分。1 以上）"),
              "deadline": strProp(
                "期限（ISO 8601 の日時。今より後。時差の無い 2026-10-13T09:00 は Mac のタイムゾーンの時刻）"),
            ],
            "required": ["description", "command", "everyMinutes", "deadline"],
          ],
        ], required: ["taskId", "condition"])
    ),
  ])
]
