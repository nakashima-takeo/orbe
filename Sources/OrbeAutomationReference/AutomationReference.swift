/// 自動化の定義と仕組みの説明の正本（英文）。MCP の自動化のツールの説明と `orb automation --help` が同じ節を出す。
///
/// 節はどのインターフェースでも同じもの（定義の JSON・応答の JSON・振る舞いの規則）だけを持ち、ツールの名前と引数の名前を書かない——MCP と CLI では
/// 呼び方が違い、MCP が使えずに CLI を読む AI に、呼べないツールを案内しないため。呼び方はインターフェースごとの文（MCP はツールの 1 文と引数の説明、
/// CLI は usage の行と CLI の注）が持つ。
///
/// 書き方の規約: 欄名・値・環境変数は 1 語ずつ `` ` `` で囲む。JSON の形・cron 式・名前の型（mcp__<server>__<tool> など）は囲まない。
/// 囲んだ語は、どれも今の形にある名前でなければならない。
public enum AutomationReference {
  /// `orb automation --help` に出す順。
  public static let sections = [
    definition, exampleSection, nodeState, runRecord, flow, pause, trial, trialResult, proposals,
  ]
}
