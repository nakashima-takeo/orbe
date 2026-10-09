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
}
