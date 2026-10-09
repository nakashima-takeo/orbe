import Foundation

/// 待ちの条件（`add_task` / `update_task`）。
func waitingConditionProp(nullable: Bool) -> [String: Any] {
  var prop = schema(
    [
      "description": strProp("何が起きたら解けるか（1 行。例「PR #214 にレビューが付いたら」）"),
      "command": strProp("確認のコマンド（終了コード 0 で解ける。成功時は標準出力の 1 行目に起きたことを書く）"),
      "everyMinutes": intProp("確認の間隔（分。1 以上）"),
      "deadline": strProp(
        "期限（ISO 8601 の日時。今より後。時差の無い 2026-10-13T09:00 は Mac のタイムゾーンの時刻）"),
    ], required: ["description", "command", "everyMinutes", "deadline"])
  prop["description"] =
    "待ちが解ける条件（待ちの理由と一緒に付ける。完了のタスクには付けられない）。Orbe は付けた直後に 1 回、以後は"
    + " everyMinutes ごとに command を `/bin/sh -c` で確かめ、終了コード 0 で待ちを外す。成功時は標準出力の 1 行目に"
    + "起きたことを短く書く（行に出る。全体は詳細に出る）。command は人の承認なしに、呼び出し元タブの作業ディレクトリ"
    + "（分からなければホーム）で走る。deadline は必須で、満たされなくても期限で必ず解ける。解けたら、人が ⌘T で"
    + "この会話を続きから再開し、起きたことが最初の入力として届く（会話が記録されるのは、呼び出し元タブの agent が"
    + "作業中のときだけ）。付け直すと確認の回数と記録は空から始まる。"
    + (nullable ? "null で条件だけを外す（待ちは残る）。" : "")
  if nullable { prop["type"] = ["object", "null"] }
  return prop
}
