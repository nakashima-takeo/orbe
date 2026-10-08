import Foundation

extension GitRunner {
  /// 呼ばれたらすぐ失敗するコマンド（エディタ・askpass の代わり）。
  private static let refusal = "/usr/bin/false"

  /// 呼び出し共通の環境変数。PATH は毎回 `ShellPATH` から取る（プロセスの事実を焼き付けない）。
  static func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = ShellPATH.shared.value()
    env["GIT_TERMINAL_PROMPT"] = "0"  // 資格情報等の対話でハングさせない
    // 対話は GUI から見えず、待てば無限に待つ。エディタ（メッセージ無しの commit・rebase の todo）と、ssh のパスフレーズ・
    // 未知のホスト鍵の確かめは、すぐ失敗するコマンドへ向けて待たずに落とす。ssh は端末が無ければ askpass を使うが、
    // `SSH_ASKPASS_REQUIRE=force` が無いと DISPLAY の有無で使うかが揺れる。
    env["GIT_EDITOR"] = Self.refusal
    env["GIT_SEQUENCE_EDITOR"] = Self.refusal
    env["GIT_MERGE_AUTOEDIT"] = "no"
    env["SSH_ASKPASS"] = Self.refusal
    env["SSH_ASKPASS_REQUIRE"] = "force"
    // pathspec の解釈を環境に変えさせない。LITERAL は `:(literal)` ごと literal にして黙って 0 件にし、
    // ICASE は `:(literal)` を貫通して別の綴りのパスに当てる。GLOB / NOGLOB は明示 magic には効かないが、
    // 両方立っていると pathspec を取る git が丸ごと fatal になる。
    for key in [
      "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
    ] {
      env.removeValue(forKey: key)
    }
    return env
  }
}
