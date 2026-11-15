import Foundation
import OrbeEditorCore

/// diff の両側の本文の出どころ。diff の種類ごとに 1 つあり、diff（`EditorDiff`）が持つ。出どころが決めるのは次の 3 つ。
///
/// - 何を保持し、何の変化で作り直すか（変われば `onChange` に `.material`）
/// - 今の材料で両側をどうするか（`resolve` が返す `EditorDiff.Resolution`）
/// - 開いた後の最初の並びが、開いた時点に追いついたとみなせるか（`isCaughtUp`）
///
/// 出どころは diff の側・並び・面に触らない。diff は `resolve` の答えに従って、両側の文書と並びを入れ替え、見せ方・面・
/// 初めての位置決めを行う。答えが `.revisions` なら、diff が裏で行差分を揃えてから両側と並びを一緒に入れ替え、揃うまでは
/// 前の両側と並びのまま待つ（開く前なら読み込み中）。
@MainActor
protocol EditorDiffSource: AnyObject {
  /// 出どころの変化を diff へ知らせる口。diff が結ぶ。
  var onChange: ((EditorDiff.SourceChange) -> Void)? { get set }
  /// 新しい側に使っている文書（無ければ、新しい側は diff が持つ版の本文の文書）。
  var document: EditorDocument? { get }
  /// 今の材料で両側をどうするか。diff が作り直すたびに呼ぶ。
  func resolve() -> EditorDiff.Resolution
  /// `resolve` の最後の答えが、開いた後の材料の取り直しが済んだ後のものであるとき true（新しい側の文書があれば、その
  /// 行差分も今の材料の古い側に対して文書の今の本文で取った結果であること）。diff はこれに加えて、見せられる中身と並びが
  /// あり、出どころが待つと答えておらず、裏の行差分も待っていないことを確かめる。
  var isCaughtUp: Bool { get }

  /// 新しい側を、同じ実体の文書 `next` にした（替えたら true。前の文書は手放さない）。
  func replaceDocument(with next: EditorDocument) -> Bool
  /// 新しい側の文書を引く口を `documents`（引き取ったセッション）に結び直す。
  func rebind(_ documents: EditorDiff.Documents)
  /// 新しい側の文書の未保存が変わった。
  func documentDirtyDidChange()
}

/// 新しい側に文書を使わない出どころ——文書の知らせでは何もしない。
extension EditorDiffSource {
  var document: EditorDocument? { nil }
  func replaceDocument(with next: EditorDocument) -> Bool { false }
  func rebind(_ documents: EditorDiff.Documents) {}
  func documentDirtyDidChange() {}
}

extension EditorDiff {
  /// 出どころの答え——今の材料で両側をどうするか。
  enum Resolution {
    /// まだ決められない（材料が揃っていない）。前の両側と並びのまま待つ。裏で取っている行差分は捨て、出どころが次に
    /// `.revisions` と答えたときに頼み直す。
    case wait
    case unavailable(Unavailable)
    /// 両側とも版の本文。diff が裏で行差分を揃えてから、両側と並びを一緒に入れ替える。同じ本文の行差分を裏で取って
    /// いれば、頼み直さずにその結果を待つ。
    case revisions(SideTexts)
    /// 両側とも版の本文で、新しい側が無いか、新しい側がサブモジュールの 1 行のとき（作業ツリー diff で、新しい側が文書で
    /// ないとき）の答え。diff がその場で（main で）行差分を取り、両側と並びを入れ替える。新しい側が無ければ行差分は本文の大きさに依らず軽いが、古い側がファイルの
    /// 本文で新しい側がサブモジュールの 1 行なら、古い側の本文の長さに比例する手間が main にかかる。
    case revisionsNow(SideTexts)
    /// 新しい側は出どころの文書、古い側は文書の行差分が比べた底の本文 `base`。並びは文書の行差分。
    case document(base: String)
    /// 新しい側は出どころの文書、古い側は文書の底ではない本文 `old`（無ければ nil）。並びは丸ごとの置き換え。
    case documentReplacing(old: String?)
  }

  /// 出どころの変化。
  enum SourceChange {
    /// 材料が変わった（diff が作り直す）。
    case material
    /// `resolve` の中で新しい側の文書が替わった（引数は前の文書。無かったなら nil）。出どころが前の文書を手放す前に届く。
    case document(previous: EditorDocument?)
  }
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
