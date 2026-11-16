import Foundation
import OrbeEditorCore

/// 作業ツリー diff の出どころ——古い側は index の版、新しい側は作業ツリーの姿（文書・消した・ディレクトリ・表示できない）。
/// 新しい側の文書はファイルタブと共有する文書（実体ごとに 1 つで、`documents` が引く）で、diff の中でも編集できる。
/// サブモジュールは「Subproject commit」の行で見せる。
///
/// 差分は文書のハンク（裏・版つき・編集でずらす）そのもので、古い側はそのハンクが比べた底から作る——底とハンクと今の
/// 本文の組は文書の中で食い違わないので、差し込みが古い側の本文とも今の本文ともずれない。
@MainActor
final class EditorDiffWorkingTree: EditorDiffSource {
  let id: EditorDiff.Key
  let files: RootFiles
  var onChange: ((EditorDiff.SourceChange) -> Void)?
  private var documents: EditorDiff.Documents
  private var catchUp: RootFilesCatchUp?
  /// 作業ツリーの姿と、それを読み直すべきか（ファイルが変わった）。
  private(set) var working: Side
  private(set) var workingStale = false
  /// 作業ツリーのサブモジュールが取り出しているコミット（外側の nil はまだ読んでいない、内側の nil は取り出していない）と、
  /// 読みの通し番号（読み直しを頼めば前の読みの結果を捨てる）。
  private var submoduleHead: String??
  private var submoduleHeadRequest = 0
  private var readsSubmoduleHead = false

  /// テキスト面を作れなければ `EditorSurfaceError.noMetalDevice` で失敗する。
  init(id: EditorDiff.Key, documents: EditorDiff.Documents) throws {
    self.id = id
    self.documents = documents
    files = RootFiles.shared(for: id.root)
    working = .missing
    working = try readWorkingTree()
    // 監視の知らせより先に開いても（エージェントが書いた直後の open_diff）、書いた中身で始める。
    document?.reconcileWithDisk()
    files.addObserver(self, versions: [RootFiles.Version(path: id.path, revision: .index)])
    catchUp = RootFilesCatchUp(files) { [weak self] in self?.onChange?(.material) }
  }

  deinit {
    let files = self.files
    MainActor.assumeIsolated { files.removeObserver(self) }
  }

  var document: EditorDocument? {
    if case .document(let document) = working { return document }
    return nil
  }

  // MARK: - 文書

  func replaceDocument(with next: EditorDocument) -> Bool {
    guard document !== next else { return false }
    working = .document(next)
    return true
  }

  func rebind(_ documents: EditorDiff.Documents) {
    self.documents = documents
  }

  /// 未保存の間に保留した作業ツリーの読み直しを、未保存でなくなった時点で行う。
  func documentDirtyDidChange() {
    guard workingStale, document?.isDirty == false else { return }
    onChange?(.material)
  }

  // MARK: - 中身

  func resolve() -> EditorDiff.Resolution {
    catchUp?.willResolve()
    if files.status?.entries[id.path]?.isConflicted == true { return .unavailable(.conflicted) }
    if workingStale { updateWorkingSide() }
    if case .unavailable(let reason) = working { return .unavailable(reason) }
    let index = files.state(of: RootFiles.Version(path: id.path, revision: .index))
    var newText: String?
    if let index, case .directory(let hasRepository) = working {
      switch submoduleSide(index, hasRepository: hasRepository) {
      case .text(let text): newText = text
      case .decided(let decided): return decided
      }
    }
    let old: String?
    switch index {
    case nil: return .wait
    case .notText?: return .unavailable(.notText)
    case .failed?: return .unavailable(.failed)
    case .absent?:
      if case .missing = working { return .unavailable(.nowhere) }
      old = nil
    case .submodule(let commit)?:
      old = EditorDiff.subproject(commit)
    case .text(let text)?:
      guard let document else {
        let texts = EditorDiff.SideTexts(old: text, new: newText)
        // 作業ツリーのディレクトリをサブモジュールの行で見せるなら、ファイルとサブモジュールの置き換え。
        return newText == nil ? .revisions(texts) : .revisionsReplacing(texts)
      }
      // 文書の行差分が新しい底に対する結果になるまでは、前の底とその行差分の組のまま。
      guard let base = document.hunksBase else { return .wait }
      return .document(base: base)
    }
    // 古い側が文書の底ではない（index の版に無い・サブモジュールの行）。このとき文書は底を持たず、行差分もその知らせも無い。
    if document != nil { return .documentReplacing(old: old) }
    return .revisions(EditorDiff.SideTexts(old: old, new: newText))
  }

  /// 開いた後の取り直しが済んだ後の状態から答えた。さらに文書があれば、その行差分が今の index の本文に対して今の本文で
  /// 取った結果である。
  var isCaughtUp: Bool {
    guard catchUp?.resolvedAfterSettling == true else { return false }
    guard let document,
      case .text(let base)? = files.state(of: RootFiles.Version(path: id.path, revision: .index))
    else { return true }
    return document.hunksAreCurrent && document.hunksBase == base
  }

  // MARK: - 作業ツリーの姿

  /// 作業ツリーの姿を読み直し、新しい側の文書を合わせる。文書が替われば、前の文書をファイルタブの見え方に戻して手放す。
  /// 今の文書が未保存なら、作業ツリーの姿が変わっても手放さず新しい側のまま——未保存の本文を確認なしに失わない（ファイル
  /// タブが、消えたファイルの未保存の本文を保つのと同じ）。読み直しは保留のまま残し、未保存でなくなった後の作り直しで
  /// 行う。読み直しでテキスト面を作れなければ、ファイルを読めないとして表示できない。
  private func updateWorkingSide() {
    if document?.isDirty == true { return }
    workingStale = false
    forgetSubmoduleHead()
    let previous = document
    do {
      working = try readWorkingTree()
    } catch {
      working = .unavailable(.unreadable)
    }
    guard document !== previous else { return }
    onChange?(.document(previous: previous))
    documents.switched(previous)
  }

  /// 作業ツリーの姿——在るか・シンボリックリンクか・ディレクトリか・UTF-8 か・読めるか。文書として読めればその文書
  /// （`documents` が実体ごとに 1 つ持つ。開いていればそれ）。途中のディレクトリがシンボリックリンクなら、git と同じく無い
  /// （リンク先を開かない）。テキスト面を作れなければ `EditorSurfaceError.noMetalDevice` を投げる。
  private func readWorkingTree() throws -> Side {
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
    } catch EditorSurfaceError.noMetalDevice {
      throw EditorSurfaceError.noMetalDevice
    } catch EditorDocumentError.notUTF8 {
      return .unavailable(.notText)
    } catch {
      return .unavailable(.unreadable)
    }
  }

  /// 作業ツリーの姿（新しい側）。
  enum Side {
    /// 開いた文書（ファイルタブと共有する）。
    case document(EditorDocument)
    /// 作業ツリーに無い（消した）。
    case missing
    /// ディレクトリ（`hasRepository` は中が取り出したリポジトリ）。index の版がサブモジュールか、中がリポジトリなら、
    /// サブモジュールとして「Subproject commit」の行で見せる。見せられなければ、理由「ディレクトリ」で表示できない。
    case directory(hasRepository: Bool)
    case unavailable(EditorDiff.Unavailable)
  }

  // MARK: - サブモジュール

  private enum SubmoduleSide {
    case text(String)
    case decided(EditorDiff.Resolution)
  }

  /// 作業ツリーのディレクトリをサブモジュールとして見せる本文——取り出しているコミット（取り出していなければ index の
  /// コミット。git と同じく変わっていないとみなす）の行。中が変わっていれば -dirty。index の版がサブモジュールでなく、中に
  /// 取り出したコミットも無ければ、サブモジュールとして見せられないディレクトリ。コミットを読み中なら待つ。
  private func submoduleSide(
    _ index: RootFiles.VersionState, hasRepository: Bool
  ) -> SubmoduleSide {
    var indexCommit: String?
    if case .submodule(let commit) = index { indexCommit = commit }
    guard indexCommit != nil || hasRepository else { return .decided(.unavailable(.directory)) }
    guard let head = submoduleHead else {
      readSubmoduleHead()
      return .decided(.wait)
    }
    guard let commit = head ?? indexCommit else { return .decided(.unavailable(.directory)) }
    return .text(EditorDiff.subproject(commit, dirty: submoduleIsDirty))
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
      onChange?(.material)
    }
  }

  /// 読んだコミットを捨てる（次の作り直しで読み直す）。
  private func forgetSubmoduleHead() {
    submoduleHead = nil
    submoduleHeadRequest += 1
    readsSubmoduleHead = false
  }
}

/// 根のサービスの知らせ——作業ツリーのファイル・status・入れ子の git dir・index の版の本文の変化で、中身を作り直す。
extension EditorDiffWorkingTree: RootFilesObserver {
  /// 作業ツリーのファイルが変わった——新しい側（文書・消えた・表示できない）を読み直す。
  func rootFiles(_ files: RootFiles, filesDidChange change: RootFiles.Change) {
    guard change.includes(id.root + "/" + id.path) else { return }
    workingStale = true
    onChange?(.material)
  }

  /// status が変わった——競合の出入り・サブモジュールの中の変化。
  func rootFilesStatusDidChange(_ files: RootFiles) {
    forgetSubmoduleHead()
    onChange?(.material)
  }

  /// 入れ子の git dir が変わった（監視の 1 バッチに 1 回）——サブモジュールが取り出しているコミットを読み直す（中で続けて
  /// コミットしても、親の status は「コミットが動いた」のまま変わらない）。
  func rootFilesNestedGitStateDidChange(_ files: RootFiles) {
    guard case .directory = working else { return }
    forgetSubmoduleHead()
    onChange?(.material)
  }

  func rootFiles(_ files: RootFiles, versionDidChange version: RootFiles.Version) {
    onChange?(.material)
  }
}
