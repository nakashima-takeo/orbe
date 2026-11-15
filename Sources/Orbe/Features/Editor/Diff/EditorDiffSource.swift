import Foundation
import OrbeEditorCore

/// diff の両側の本文の出どころ。diff の種類ごとに 1 つあり、diff（`EditorDiff`）が持つ。出どころが決めるのは、何を保持し、
/// 何の変化で作り直すか（変われば `onChange`）、開いた後の最初の並びがいつ追いついたとみなせるか、両側の本文か、表示できない
/// 理由のどちらか。見せ方・面・並び・位置決めは diff が持ち、種類に依らない。
///
/// 両側とも版の本文である出どころは、決めた本文を `EditorDiff.showRevisions` に渡す——diff が裏で行差分を揃えてから、両側と
/// 並びを一緒に入れ替える。新しい側に文書を使う出どころ（作業ツリー）は、文書のハンクを並びに使う。
@MainActor
protocol EditorDiffSource: AnyObject {
  /// 材料が変わった（diff が作り直す）。diff が結ぶ。
  var onChange: (() -> Void)? { get set }
  /// 新しい側に使っている文書（無ければ、新しい側は diff が持つ版の本文の文書）。
  var document: EditorDocument? { get }
  /// 中身を決め、見せられるなら `diff` の側を今の材料に合わせる。まだ決められなければ `diff.pendingContent` を返す（前の
  /// 中身のまま待つ）。
  func resolve(in diff: EditorDiff) -> EditorDiff.Content
  /// 今の古い側と新しい側の本文に対して正しいと分かっている行差分と、新しい側の大きさ（並べられなければ nil）。
  func rows(in diff: EditorDiff) -> (hunks: [LineHunk], newSide: DiffRows.Side)?
  /// 見せている並びが、開いた時点に追いついている（diff が中身を見せられて、並びを持つときに問う）。
  func isCaughtUp(in diff: EditorDiff) -> Bool

  /// 新しい側を、同じ実体の文書 `next` にした（替えたら true。前の文書は手放さない）。
  func replaceDocument(with next: EditorDocument) -> Bool
  /// 新しい側の文書を引く口を `documents`（引き取ったセッション）に結び直す。
  func rebind(_ documents: EditorDiff.Documents)
  /// 新しい側の文書の未保存が変わった。
  func documentDirtyDidChange()
  /// 新しい側の文書の本文が変わった（diff を見せている間だけ届く）。
  func documentTextDidChange(in diff: EditorDiff)
}

/// 新しい側に文書を使わない出どころ——両側とも版の本文で、並びは diff が裏で揃えた行差分。文書の知らせは何もしない。
extension EditorDiffSource {
  var document: EditorDocument? { nil }
  func rows(in diff: EditorDiff) -> (hunks: [LineHunk], newSide: DiffRows.Side)? {
    (diff.revisionHunks, diff.newRevisionSide)
  }
  func replaceDocument(with next: EditorDocument) -> Bool { false }
  func rebind(_ documents: EditorDiff.Documents) {}
  func documentDirtyDidChange() {}
  func documentTextDidChange(in diff: EditorDiff) {}
}

/// 根のサービスから両側を読む出どころ（作業ツリー・ステージ済み）が、開いた後の取り直しを待つ口。開いたときに status と
/// 版の本文の取り直しを頼み（根が git 管理下かをまだ判定していなければ、判定の後に始める最初の取り直し）、両方済めば
/// `settled` を呼ぶ。済んだ後に決めた中身は、開いた時点に追いついている。
@MainActor
final class RootFilesCatchUp {
  private var awaited = 2
  /// 両方の取り直しが済んでから、中身を決め直した。
  private(set) var resolvedAfterSettling = false

  init(_ files: RootFiles, settled: @escaping () -> Void) {
    let done: () -> Void = { [weak self] in
      guard let self else { return }
      awaited -= 1
      if awaited == 0 { settled() }
    }
    files.requestStatusRefresh(then: done)
    files.requestVersionRefresh(then: done)
  }

  /// 出どころが中身を決め始めた。
  func willResolve() {
    if awaited == 0 { resolvedAfterSettling = true }
  }
}

extension EditorDiff {
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
