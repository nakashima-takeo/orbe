import Foundation
import OrbeEditorCore

/// 並び——見せている見せ方の見え方を面に載せる。
extension EditorDiff {
  /// 見せている見せ方の見え方を面に載せる（並列なら古い側の面を用意して結ぶ）。新しい側は読むだけで、作業ツリーの文書は
  /// diff の上限で行差分を取る。
  func applyRows() {
    guard let mode = presented, content == .ready, let surface = newSurface, let old,
      let (hunks, newSide) = currentRows
    else { return }
    switch mode {
    case .inline:
      var rows = DiffRows.inline(hunks, old: oldSide, new: newSide)
      rows.source = old
      look(DiffStyle.inline, rows).apply(to: surface, document: document)
    case .side:
      let rows = DiffRows.side(hunks, old: oldSide, new: newSide)
      let left = oldSurface ?? makeOldSurface()
      if let left { look(DiffStyle.side, rows.left).apply(to: left, document: nil) }
      look(DiffStyle.side, rows.right).apply(to: surface, document: document)
      if let left, oldSurface == nil {
        carryTop(to: surface)
        oldSurface = left
        surface.shareScroll(with: left)
        surfacesChanged = true
      }
    }
    carryTop(to: surface)
    revealFirstChange(on: surface)
  }

  /// 作り直した新しい側の面で、前の面の先頭の行を先頭に見せる（見えている高さより高い区間は先頭の行が上端に来る）。
  private func carryTop(to surface: any TextSurface) {
    guard let (row, lines) = carriedTop, let text = newRevision?.text else { return }
    carriedTop = nil
    revealed = true
    let from = min(row, text.lineCount - 1)
    let to = min(from + max(lines, 1), text.lineCount - 1)
    surface.reveal(
      NSRange(location: text.lineStart(from), length: text.lineEnd(to) - text.lineStart(from)),
      policy: .center)
  }

  /// 今の古い側と新しい側の本文に対して正しいと分かっている行差分と、新しい側の大きさ。作業ツリー diff の新しい側の文書は
  /// 外の書き換えでいつでも変わるので、文書の今の本文と、文書のハンク（今の本文へずらしてある）を直に使い、ハンクが比べた底
  /// が今の古い側でなければ（古い側を入れ替える前）並べない——面に残っている並びは面自身の編集に付いて動くので、今の本文と
  /// 食い違わない。
  var currentRows: (hunks: [LineHunk], newSide: DiffRows.Side)? {
    guard let document else { return (revisionHunks, newSide) }
    let side = DiffRows.Side(document.text)
    guard let oldSource else { return nil }
    guard let base = oldSource else { return (DiffRows.wholeHunks(old: .absent, new: side), side) }
    guard document.hunksBase == base else { return nil }
    return (document.hunks, side)
  }

  private func look(_ presentation: SurfacePresentation, _ rows: SurfaceRows) -> SurfaceLook {
    SurfaceLook(
      presentation: presentation, rows: rows, isEditable: false, hunkLimit: Self.hunkLimit)
  }

  private func makeOldSurface() -> (any TextSurface)? {
    guard let old, let surface = surfaces.make() else { return nil }
    old.attach(surface)
    return surface
  }

  /// 初めて並びを置いたときに、最初の変更区間が見える位置へ送る——区間の上の文脈の行から区間の終わりまで（インラインの
  /// 削除行はその間に差し込まれる）を、中央から、収まらなければ上端から見せる。
  private func revealFirstChange(on surface: any TextSurface) {
    guard !revealed, let first = currentRows?.hunks.first else { return }
    revealed = true
    let text = document?.text ?? newRevision?.text ?? TextRope()
    let start = first.newCount > 0 ? first.newStart - 1 : first.newStart
    let from = min(max(0, start - 1), text.lineCount - 1)
    let to = min(max(from, start + first.newCount - 1), text.lineCount - 1)
    surface.reveal(
      NSRange(location: text.lineStart(from), length: text.lineEnd(to) - text.lineStart(from)),
      policy: .center)
  }
}
