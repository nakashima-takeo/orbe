import Foundation

/// ステージ済み diff の出どころ——古い側は HEAD の版（rename なら元のパス）、新しい側は index の版。両側とも編集されない版の
/// 本文なので、どちらかの版が替わったときに、diff が裏で行差分を揃えてから入れ替える（→ `EditorDiff.showRevisions`）。
@MainActor
final class EditorDiffStaged: EditorDiffSource {
  let id: EditorDiff.Key
  let files: RootFiles
  var onChange: (() -> Void)?
  private var catchUp: RootFilesCatchUp?

  init(id: EditorDiff.Key) {
    self.id = id
    files = RootFiles.shared(for: id.root)
    files.addObserver(self, versions: interests)
    catchUp = RootFilesCatchUp(files) { [weak self] in self?.onChange?() }
  }

  deinit {
    let files = self.files
    MainActor.assumeIsolated { files.removeObserver(self) }
  }

  /// HEAD の版を引くパス（rename なら元のパス。status から引く）。
  private var headPath: String {
    files.status?.entries[id.path]?.originalPath ?? id.path
  }

  /// 根のサービスに本文を追わせる版——HEAD（rename なら元のパス）と index。
  private var interests: Set<RootFiles.Version> {
    [
      RootFiles.Version(path: headPath, revision: .head),
      RootFiles.Version(path: id.path, revision: .index),
    ]
  }

  /// status で関心の版が替わった（rename の元パス）直後など、今の関心の版の状態がまだ無い間は、直前に見せていた両側と並びの
  /// まま待つ。
  func resolve(in diff: EditorDiff) -> EditorDiff.Content {
    catchUp?.willResolve()
    if files.status?.entries[id.path]?.isConflicted == true { return .unavailable(.conflicted) }
    let head = files.state(of: RootFiles.Version(path: headPath, revision: .head))
    let index = files.state(of: RootFiles.Version(path: id.path, revision: .index))
    guard let head, let index else { return diff.waitForRevisions() }
    for state in [head, index] {
      if state == .notText { return .unavailable(.notText) }
      if state == .failed { return .unavailable(.failed) }
    }
    if head == .absent, index == .absent { return .unavailable(.nowhere) }
    return diff.showRevisions(
      EditorDiff.SideTexts(old: EditorDiff.sideText(head), new: EditorDiff.sideText(index)))
  }

  /// 開いた後の取り直しが済んだ後の status で決まる関心の版の状態が揃い、かつ両側の本文の行差分が届いた。
  func isCaughtUp(in diff: EditorDiff) -> Bool {
    catchUp?.resolvedAfterSettling == true && !diff.revisionsPending
  }
}

/// 根のサービスの知らせ——status（競合の出入り・rename の元パス）と版の本文の変化で、中身を作り直す。
extension EditorDiffStaged: RootFilesObserver {
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {}

  func rootFilesStatusDidChange(_ files: RootFiles) {
    files.setVersions(interests, for: self)
    onChange?()
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {
    onChange?()
  }
}
