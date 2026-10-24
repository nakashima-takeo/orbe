import Foundation
import OrbeEditorCore

/// 作業ツリー diff の側——作業ツリーの姿（文書・消した・ディレクトリ・表示できない）と index の版から、古い側と新しい側を
/// 決める。サブモジュールは「Subproject commit」の行で見せる。
extension EditorDiff {
  /// 作業ツリーの姿を読み直し、新しい側の文書を合わせる。文書が替われば、前の文書をファイルタブの見え方に戻して手放す。
  /// 今の文書が未保存なら、作業ツリーの姿が変わっても手放さず新しい側のまま——未保存の本文を確認なしに失わない（ファイル
  /// タブが、消えたファイルの未保存の本文を保つのと同じ）。読み直しは保留のまま残し、未保存でなくなった後の作り直しで
  /// 行う。
  func updateWorkingSide() {
    if document?.isDirty == true { return }
    workingStale = false
    forgetSubmoduleHead()
    let previous = document
    working = try? readWorkingTree(throwing: false)
    guard document !== previous else { return }
    documentDidSwitch(from: previous)
    documents.switched(previous)
  }

  /// 作業ツリーの姿——在るか・シンボリックリンクか・ディレクトリか・UTF-8 か。文書として読めればその文書（`documents` が
  /// 実体ごとに 1 つ持つ。開いていればそれ）。途中のディレクトリがシンボリックリンクなら、git と同じく無い（リンク先を
  /// 開かない）。`throwing` なら、テキスト面を作れないことを投げる（開くとき）。
  func readWorkingTree(throwing: Bool) throws -> WorkingSide {
    let url = id.url
    let parent = (id.root as NSString).appendingPathComponent(
      (id.path as NSString).deletingLastPathComponent)
    guard
      GitWorktreeRoot.normalizedPath(evenIfMissing: url.deletingLastPathComponent().path)
        == parent
    else { return .missing }
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return .missing
    }
    switch attributes[.type] as? FileAttributeType {
    case .typeSymbolicLink?: return .unavailable(.symlink)
    case .typeDirectory?:
      return .directory(
        hasRepository: FileManager.default.fileExists(
          atPath: url.appendingPathComponent(".git").path))
    default: break
    }
    do {
      // 開いている文書は読み直さないので、UTF-8 かはファイルから確かめる。
      _ = try EditorDocument.read(url)
      return .document(try documents.open(url.resolvingSymlinksInPath()))
    } catch EditorSurfaceError.noMetalDevice where throwing {
      throw EditorSurfaceError.noMetalDevice
    } catch EditorDocumentError.notUTF8 {
      return .unavailable(.notText)
    } catch {
      return .unavailable(.failed)
    }
  }

  func resolveWorkingTree() -> Content {
    if workingStale { updateWorkingSide() }
    guard let working else { return .loading }
    if case .unavailable(let reason) = working { return .unavailable(reason) }
    let pending: Content = content == .ready ? .ready : .loading
    let index = files.state(of: RootFiles.Version(path: id.path, revision: .index))
    var newText: String?
    if index != nil, case .directory(let hasRepository) = working {
      switch submoduleSide(hasRepository: hasRepository, pending: pending) {
      case .text(let text): newText = text
      case .decided(let decided): return decided
      }
    }
    if let decided = resolveOldSide(index, working: working, pending: pending) { return decided }
    guard document == nil, let old else { return .ready }
    setNewRevision(newText, keepsOld: true)
    revisionHunks = DiffRows.hunks(
      old: oldSide.isAbsent ? nil : old.text,
      new: newRevisionSide.isAbsent ? nil : newRevision?.text, limit: Self.hunkLimit)
    return .ready
  }

  /// 古い側を index の版の状態から決める（まだ決められない・表示できないなら、その中身）。文書があれば、古い側は文書の
  /// ハンクが比べた底——ハンクが新しい底に対する結果になるまでは、前の底とそのハンクの組のまま。
  private func resolveOldSide(
    _ index: RootFiles.VersionState?, working: WorkingSide, pending: Content
  ) -> Content? {
    oldIsSubmodule = false
    switch index {
    case nil: return pending
    case .notText?: return .unavailable(.notText)
    case .failed?: return .unavailable(.failed)
    case .absent?:
      if case .missing = working { return .unavailable(.nowhere) }
      setOld(nil)
    case .submodule(let commit)?:
      oldIsSubmodule = true
      setOld(Self.subproject(commit))
    case .text(let text)?:
      guard let document else {
        setOld(text)
        return nil
      }
      guard let base = document.hunksBase else { return pending }
      setOld(base)
    }
    return nil
  }

  private enum SubmoduleSide {
    case text(String)
    case decided(Content)
  }

  /// 作業ツリーのディレクトリをサブモジュールとして見せる本文——取り出しているコミット（取り出していなければ index の
  /// コミット。git と同じく変わっていないとみなす）の行。中が変わっていれば -dirty。index の版がサブモジュールでなく、中も
  /// リポジトリでなければ表示できない。コミットを読み中なら `pending`。
  private func submoduleSide(hasRepository: Bool, pending: Content) -> SubmoduleSide {
    var indexCommit: String?
    if case .submodule(let commit)? = files.state(
      of: RootFiles.Version(path: id.path, revision: .index))
    {
      indexCommit = commit
    }
    guard indexCommit != nil || hasRepository else { return .decided(.unavailable(.failed)) }
    guard let head = submoduleHead else {
      readSubmoduleHead()
      return .decided(pending)
    }
    guard let commit = head ?? indexCommit else { return .decided(.unavailable(.failed)) }
    return .text(Self.subproject(commit, dirty: submoduleIsDirty))
  }

  /// 作業ツリーのサブモジュールの中が変わった・未追跡がある（status が言う）。
  private var submoduleIsDirty: Bool {
    switch files.status?.entries[id.path]?.unstagedSubmodule {
    case .content?, .commit(dirty: true)?: true
    default: false
    }
  }

  /// 作業ツリーのサブモジュールが取り出しているコミットを根のサービスから読み、届いたら作り直す。
  private func readSubmoduleHead() {
    guard !readsSubmoduleHead else { return }
    readsSubmoduleHead = true
    let request = submoduleHeadRequest
    files.submoduleHead(of: id.path) { [weak self] head in
      guard let self, request == submoduleHeadRequest else { return }
      readsSubmoduleHead = false
      submoduleHead = .some(head)
      sourcesDidChange()
    }
  }

  /// 読んだコミットを捨てる（次の作り直しで読み直す）。
  func forgetSubmoduleHead() {
    submoduleHead = nil
    submoduleHeadRequest += 1
    readsSubmoduleHead = false
  }

  /// git がサブモジュールの側を diff に起こす 1 行（末尾の改行は付けない——1 行のまま、空の行を足さない）。
  static func subproject(_ commit: String, dirty: Bool = false) -> String {
    "Subproject commit " + commit + (dirty ? "-dirty" : "")
  }

  /// 版の状態の、diff の側の本文（ファイルは本文、サブモジュールは「Subproject commit」の 1 行、その版に無ければ nil）。
  static func sideText(_ state: RootFiles.VersionState) -> String? {
    if case .submodule(let commit) = state { return subproject(commit) }
    return state.text
  }
}
