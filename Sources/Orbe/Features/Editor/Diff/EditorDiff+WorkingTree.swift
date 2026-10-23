import Foundation
import OrbeEditorCore

/// 作業ツリー diff の側——作業ツリーの姿（文書・消した・表示できない）と index の版から、古い側と新しい側を決める。
extension EditorDiff {
  /// 作業ツリーの姿を読み直し、新しい側の文書を合わせる。文書が替われば、前の文書をファイルタブの見え方に戻して手放す。
  /// 今の文書が未保存なら、作業ツリーの姿が変わっても手放さず新しい側のまま——未保存の本文を確認なしに失わない（ファイル
  /// タブが、消えたファイルの未保存の本文を保つのと同じ）。読み直しは保留のまま残し、未保存でなくなった後の作り直しで
  /// 行う。
  func updateWorkingSide() {
    if document?.isDirty == true { return }
    workingStale = false
    let previous = document
    working = try? readWorkingTree(throwing: false)
    guard document !== previous else { return }
    documentDidSwitch(from: previous)
    documents.switched(previous)
  }

  /// 作業ツリーの姿——在るか・シンボリックリンクか・UTF-8 か。文書として読めればその文書（`documents` が
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
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      return .unavailable(.symlink)
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
    if let decided = resolveOldSide(index, working: working, pending: pending) { return decided }
    guard document == nil, let old else { return .ready }
    setNewRevision(nil, keepsOld: true)
    revisionHunks = DiffRows.hunks(
      old: oldSide.isAbsent ? nil : old.text, new: nil, limit: Self.hunkLimit)
    return .ready
  }

  /// 古い側を index の版の状態から決める（まだ決められない・表示できないなら、その中身）。文書があれば、古い側は文書の
  /// ハンクが比べた底——ハンクが新しい底に対する結果になるまでは、前の底とそのハンクの組のまま。
  private func resolveOldSide(
    _ index: RootFiles.VersionState?, working: WorkingSide, pending: Content
  ) -> Content? {
    switch index {
    case nil: return pending
    case .notText?: return .unavailable(.notText)
    case .failed?: return .unavailable(.failed)
    case .absent?:
      if case .missing = working { return .unavailable(.nowhere) }
      setOld(nil)
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
}
