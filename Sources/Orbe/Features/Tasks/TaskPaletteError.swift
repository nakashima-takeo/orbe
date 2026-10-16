import Foundation

/// フッターに赤で出す失敗。画面が「何をしようとしたか」から選ぶ（ストアのエラーの文は読まない）。
enum TaskPaletteError: Error, Equatable {
  case title, waiting, due, failed
  /// 解けた待ちの「続きから」で、会話の CLI が見つからない。
  case agentMissing
  /// 解けた待ちの「続きから」で、会話の作業ディレクトリが無い。
  case directoryMissing
  /// GitHub に自分をアサイン・レビュアーにする書き込みが失敗した。
  case assign
  /// タスクにするを、ストアが受け付けなかった（間に agent がその項目を結び付けていた）。
  case link
  /// claude が見つからないので agent に任せられない。
  case secretaryClaude
  /// agent を起動できなかった。
  case secretaryUnavailable
}

extension TaskPaletteError {
  /// 画面に出す文。
  var message: L10nKey {
    switch self {
    case .title: .taskPaletteErrTitle
    case .waiting: .taskPaletteErrWaiting
    case .due: .taskPaletteErrDue
    case .failed: .taskPaletteErrFailed
    case .assign: .taskPaletteErrAssign
    case .link: .taskPaletteErrLink
    case .secretaryClaude: .taskPaletteErrSecretaryClaude
    case .secretaryUnavailable: .taskPaletteErrSecretaryUnavailable
    case .agentMissing: .taskPaletteErrAgentMissing
    case .directoryMissing: .taskPaletteErrDirectoryMissing
    }
  }
}
