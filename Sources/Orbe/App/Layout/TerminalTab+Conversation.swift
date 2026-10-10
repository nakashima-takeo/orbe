import Foundation

extension TerminalTab {
  /// 会話へ今、文字を貼って Enter してよいか（秘書へ届ける・解けた待ちの続きから）。起きていて、agent が入力を受けられる
  /// 状態（idle / done）を報告していて、報告したときの端末の前面のプロセスグループ（報告者が属していた＝報告した agent）が
  /// 今も前面にいて止まっていないときだけ。agent が終わった・Ctrl+Z で止まった後の前面はシェルか止まった agent で、
  /// tmux の中の agent の報告は前面を持たないので、貼った文字がシェルのコマンドとして実行されることも、止まった agent の
  /// 入力に溜まることもない。
  var acceptsConversationInput: Bool {
    guard !isDormant, let report = agentReport, report.state == "idle" || report.state == "done",
      let group = report.foregroundGroup, surface.foregroundProcessGroup == group
    else { return false }
    return ProcessGroup.isRunning(group)
  }

  /// 今の端末の前面のプロセスグループで、報告者がそこに属するもの（報告した agent の前面）。属さなければ nil。
  func foreground(reportedBy report: AgentHookReport) -> pid_t? {
    surface.foregroundProcessGroup.flatMap { $0 == report.reporterGroup ? $0 : nil }
  }
}
