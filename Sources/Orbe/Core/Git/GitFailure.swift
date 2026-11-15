import Foundation

/// git 操作の失敗理由。**文言は持たない**（UI 言語は chrome の責務で、Git 層は理由だけを返す）。
/// モデル層がこれを受けて文言へ写す。
enum GitFailure: Equatable {
  /// 無出力が続いて打ち切った。git は何も言い残していないので、chrome が文言を用意する。
  case timedOut
  /// git の出力（stderr、それが空なら stdout）から取り出した実質的な理由。そのまま見せる。
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

/// 書き込み（ステージ・解除・破棄・コミット・取り消し・pull・push・fetch）の失敗。**文言は持たない**。
/// 書き込みの手のうち見ていない手（無出力で打ち切る）は人が見ていない裏の fetch だけで、その失敗は人に見せないので、
/// 打ち切りは分けずに「その他」に入る。
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
  /// push を断られた（サーバーの hook・保護ブランチ・`already exists` など、取り込んでも直らない）。理由は git の要約の
  /// まま（送れなかった ref とその要約を頭に置く）。リモートとは話せている。
  case remoteRefused(String)
  /// pull が競合で止まった（pull の前に無かった操作が、後に在る）。
  case conflicted(GitWorktreeOperation)
  /// merge・rebase 等の途中で pull しようとした。
  case operationInProgress(GitWorktreeOperation)
  /// upstream の無いブランチを pull しようとした。
  case noUpstream
  /// upstream も push 先の設定も origin も無いブランチを push しようとした。
  case noPushDestination
  /// ブランチに居ない（detached HEAD）。push・pull と、初回コミットの取り消しが要る。
  case detached
  /// コミットしようとした index に競合（unmerged のパス）が残っている。git はコミットを必ず断るので、何も書かずに返す。
  case conflictsRemain
  /// コミット・amend・取り消しで、HEAD かコミットに入るものが押した時点に見えていたものと違う（行が status に追いついて
  /// いない・外で index や HEAD が動いた）。何も書かずに返す——見えていないコミットの上に重ねない・書き換えない・取り消さ
  /// ない。git はコミットに index 全体を入れるので、見えていない変更も入れない。破棄で、パスの行き先（ゴミ箱か、index の版へ
  /// 戻すか）が押した時点に見えていたものと違うときも同じ。
  case contentMismatch
  /// amend・取り消しで書き換えようとした HEAD が push 済み（どれかの remote 追跡ブランチから届く）。force push を持たない
  /// ので、書き換えれば Orbe の中では戻せない。
  case headPushed
  /// 最後のコミットの親が手元に無い（shallow clone の境界）。取り消すと、ブランチを消して履歴とつながらない初回コミット前に
  /// 化けるので取り消さない。
  case shallowBoundary
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
