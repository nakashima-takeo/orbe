import Foundation

/// 失敗の分類 → 文（理由と次の一手）の写しの 1 か所。分類できない失敗は git の理由の行そのまま。止めた・管理外は文にしない
/// （管理外はパネル全体が理由の一文になる）。ブランチに居ない断りは、断った操作（プル・プッシュか、初回コミットの取り消し
/// か）を言う。
enum ScmFailureText {
  static func text(_ failure: SourceControl.Failure, _ language: Language) -> String? {
    switch failure.cause {
    case .git(.detached) where failure.kind == .undo:
      L10n.string(.editorScmFailureUndoDetached, language)
    case .git(let gitFailure): text(gitFailure, language)
    case .networkBusy: L10n.string(.editorScmFailureNetworkBusy, language)
    case .rewriteDuringNetwork: L10n.string(.editorScmFailureRewriteDuringNetwork, language)
    case .pushDuringRewrite: L10n.string(.editorScmFailurePushDuringRewrite, language)
    }
  }

  private static func text(_ failure: GitWriteFailure, _ language: Language) -> String? {
    switch failure {
    case .cancelled, .notManaged: nil
    case .authentication: L10n.string(.editorScmFailureAuthentication, language)
    case .unknownHostKey: L10n.string(.editorScmFailureHostKey, language)
    case .pushRejected: L10n.string(.editorScmFailurePushRejected, language)
    case .conflicted(let operation):
      L10n.format(.editorScmFailureConflicted, language, operation.name)
    case .operationInProgress(let operation):
      L10n.format(.editorScmFailureInProgress, language, operation.name)
    case .detached: L10n.string(.editorScmFailureDetached, language)
    case .noUpstream: L10n.string(.editorScmFailureNoUpstream, language)
    case .noPushDestination: L10n.string(.editorScmFailureNoPushDestination, language)
    case .conflictsRemain: L10n.string(.editorScmFailureConflictsRemain, language)
    case .contentMismatch: L10n.string(.editorScmFailureContentMismatch, language)
    case .headPushed: L10n.string(.editorScmFailureHeadPushed, language)
    case .shallowBoundary: L10n.string(.editorScmFailureShallow, language)
    case .reason(let reason): reason
    }
  }
}
