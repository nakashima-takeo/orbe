import Foundation

/// git 操作の失敗理由。**文言は持たない**（UI 言語は chrome の責務で、Git 層は理由だけを返す）。
/// モデル層がこれを受けて文言へ写す。
enum GitFailure: Equatable {
  /// 無出力が続いて打ち切った。git は何も言い残していないので、chrome が文言を用意する。
  case timedOut
  /// git の stderr から取り出した実質的な理由。そのまま見せる。
  case reason(String)
}

/// ブランチの最新化（fetch → fast-forward）がどの段で落ちたか。
enum GitRefreshFailure: Error, Equatable {
  /// remote からの fetch が落ちた。
  case fetch(GitFailure)
  /// ローカル ref を進められなかった。nil は upstream と分岐していて fast-forward できない
  /// （git は何も言わないので理由は chrome が用意する）。非 nil は git が拒んだ理由（checkout 中など）。
  case fastForward(GitFailure?)
}

/// 利用者が起こした書き込み（ステージ・解除・破棄・コミット・pull・push・fetch）の失敗。**文言は持たない**。
/// 書き込みは無出力で打ち切らない（止めるのは利用者）ので、打ち切りは無い。リモートの操作の失敗だけが分類を持ち、
/// 分類できない失敗は「その他」（`reason`）に倒す——誤分類より安全。
enum GitWriteFailure: Error, Equatable {
  /// 止めた。
  case cancelled
  /// git 管理外の根。
  case notManaged
  /// 認証が要る、または拒まれた（ssh の鍵・https の資格情報）。
  case authentication
  /// ssh のホスト鍵が未知（確かめる対話は封じてある）。
  case unknownHostKey
  /// push が拒否された（先に取り込みが要る）。
  case pushRejected
  /// pull が競合で止まった（pull の前に無かった操作が、後に在る）。
  case conflicted(GitWorktreeOperation)
  /// merge・rebase 等の途中で pull しようとした。
  case operationInProgress(GitWorktreeOperation)
  /// upstream の無いブランチを pull しようとした。
  case noUpstream
  /// upstream も origin も無いブランチを push しようとした。
  case noPushDestination
  /// ブランチに居ない（detached HEAD）。push と、初回コミットの取り消しが要る。
  case detached
  /// その他。git の実質的な理由をそのまま。
  case reason(String)

  /// 終わった実行の失敗（成功なら nil）。止めた・その他だけを読む。
  static func of(_ output: GitRunner.Output) -> GitWriteFailure? {
    if output.ending == .cancelled { return .cancelled }
    return output.isSuccess ? nil : .reason(GitRepo.failureReason(of: output))
  }

  /// リモートと話す実行（fetch・pull・push）の失敗。認証とホスト鍵だけは stderr の字面で読む——git も ssh も
  /// それを機械向けの形で出さない。
  static func ofRemote(_ output: GitRunner.Output) -> GitWriteFailure? {
    let failure = of(output)
    guard case .reason = failure else { return failure }
    let stderr = output.stderrText
    if stderr.contains("Host key verification failed") { return .unknownHostKey }
    let authentication = [
      "Permission denied (publickey", "Authentication failed", "could not read Username",
      "could not read Password", "terminal prompts disabled",
    ]
    if authentication.contains(where: stderr.contains) { return .authentication }
    return failure
  }
}
