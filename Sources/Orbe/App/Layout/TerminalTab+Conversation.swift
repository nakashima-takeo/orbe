import Foundation

extension TerminalTab {
  /// 会話へ今、文字を貼って Enter してよいか（秘書へ届ける・解けた待ちの続きから）。起きていて、agent が入力を受けられる
  /// 状態（idle / done）を報告していて、報告したときの端末の前面のプロセスグループ（報告した agent）が今も前面にいて
  /// 止まっていないときだけ。agent が終わった・Ctrl+Z で止まった後の前面はシェルか止まった agent なので、貼った文字が
  /// シェルのコマンドとして実行されることも、止まった agent の入力に溜まることもない。
  var acceptsConversationInput: Bool {
    guard !isDormant, let report = agentReport, report.state == "idle" || report.state == "done",
      let group = report.foregroundGroup, surface.foregroundProcessGroup == group
    else { return false }
    return ProcessGroup.isRunning(group)
  }
}
