import Foundation

extension TerminalTab {
  /// 報告している会話が、今もこのタブの前面にいると確かか。言えるのは、その agent をタブのコマンドとして起こした
  /// タブか、終了を報告する CLI のタブだけ（どちらも、agent が去れば同一性が残らない）。終了を報告しない CLI を
  /// シェルで手で起こしたタブでは、agent が終わった後も状態が残り、前面にはシェルがいうる。
  var conversationIsForeground: Bool {
    guard let command = agentSlot.session?.command else { return false }
    return launchedAgent == command || AgentCatalog.profile(command)?.reportsExit == true
  }
}
