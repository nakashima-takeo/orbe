import Foundation
import OrbeEditorCore

/// 並び——見せている見せ方の見え方を面に載せる。
extension EditorDiff {
  /// 見せている見せ方の見え方を面に載せる（並列なら古い側の面を用意して結ぶ）。作業ツリーの文書は diff の上限で行差分を
  /// 取る。文書のハンクが変わるたびに呼ばれ（編集でハンクをずらしたときは、その編集の知らせの中で）、同じ並びの押し直しは
  /// 面が何もしない。
  func applyRows() {
    guard let mode = presented, content == .ready, let surface = newSurface, let old,
      let (hunks, newSide) = currentRows
    else { return }
    let notes = comments?.notes(shown: revisionHunksSides?.texts) ?? DiffRows.Notes()
    switch mode {
    case .inline:
      var rows = DiffRows.inline(hunks, new: newSide, notes: notes)
      rows.source = old
      rows.trailingMarkTarget = comments
      look(
        comments == nil ? DiffStyle.inline : DiffStyle.pullRequestInline, rows,
        absent: newSide.isAbsent
      ).apply(to: surface, document: document)
      comments?.place(old: nil, new: surface)
    case .side:
      var rows = DiffRows.side(hunks, old: oldSide, new: newSide, notes: notes)
      rows.left.trailingMarkTarget = comments
      rows.right.trailingMarkTarget = comments
      let presentation = comments == nil ? DiffStyle.side : DiffStyle.pullRequestSide
      let left = oldSurface ?? makeOldSurface()
      if let left {
        look(presentation, rows.left, absent: oldSide.isAbsent).apply(to: left, document: nil)
      }
      look(presentation, rows.right, absent: newSide.isAbsent)
        .apply(to: surface, document: document)
      comments?.place(old: left, new: surface)
      if let left, oldSurface == nil {
        oldSurface = left
        surface.shareScroll(with: left)
        surfacesChanged = true
      }
    }
    placeFirstView(on: surface)
    revealRequestedThread()
    sendVisibleRemovedLines(on: surface)
  }

  /// インラインなら、新しい側の面 `surface` に見えている削除行（古い側の行）を古い側の文書へ渡し、その色を先に作らせる。
  /// 並びを置くたびにも渡す——隠れている間や見せている間に作り直した古い側の文書は、見えている範囲をまだ受けていない。
  func sendVisibleRemovedLines(on surface: any TextSurface) {
    guard presented == .inline, let old, let hunks = currentRows?.hunks else { return }
    let viewport = surface.viewport
    old.setVisible(
      lines: DiffRows.oldLines(
        from: surface.lineRow(of: viewport.top), count: Int(viewport.visibleLines.rounded(.up)),
        hunks))
  }

  /// 面に初めて見せる位置へ送る——位置を決めた後に作り直した面なら前の面で先頭に見えていた所、まだなら、開いた時点に
  /// 追いついた並びで 1 回だけ最初の変更区間（無ければ送らない）。どちらも見えている高さで決まる位置なので、面がまだ大きさを
  /// 持たない（本体に置いた直後の配置の前）なら送らず、大きさが決まって見えている範囲が変わったとき（`viewportDidChange`）に
  /// 送る。初めての位置を決めたら pane へ知らせる——中身も面も変わらず位置だけが決まったときも、pane に配置を頼ませ、その
  /// 配置で色を待たせる。
  func placeFirstView(on surface: any TextSurface) {
    switch placement {
    case .placed:
      guard surface.viewport.visibleLines > 0 else { return }
      carryTop(to: surface)
    case .catchingUp, .sizing:
      guard placement == .sizing || isCaughtUp else { return }
      placement = .sizing
      guard surface.viewport.visibleLines > 0 else { return }
      placement = .placed
      revealFirstChange(on: surface)
      onPresentationChange?()
    }
  }

  /// 並びが開いた時点に追いついている。条件は 3 つ——中身を見せられて並びがある、出どころが待つと答えておらず裏の行差分も
  /// 待っていない、出どころが追いついたと言っている。
  var isCaughtUp: Bool {
    content == .ready && currentRows != nil && !pending && source.isCaughtUp
  }

  /// 作り直した新しい側の面で、前の面で先頭に見えていた所を先頭に置く。
  private func carryTop(to surface: any TextSurface) {
    guard let carried, let hunks = currentRows?.hunks else { return }
    self.carried = nil
    switch carried {
    case .anchor(let anchor):
      surface.scroll(
        to: surface.position(
          ofLineRow: DiffRows.lineRow(of: anchor, hunks, side: presented == .side)))
    case .position(let position):
      surface.scroll(to: position)
    }
  }

  /// 今の古い側と新しい側の本文に対して正しいと分かっている並びと、新しい側の大きさ。並びを面へ置く所と、今の面の上で
  /// 並びから位置を求める所は、どれもここを通る（作り直す前の面の錨は、前の並びから求める——`setNewRevision`）——今の
  /// 両側の並びと分からなければ nil を返し、どの順で側が替わっても、合わない並びを面へ置かない。新しい側が版の本文なら、
  /// 並びを作った両側が今の両側のまま（`revisionHunksSides` が付いている）のときだけ返す。新しい側の文書は外の書き換えで
  /// いつでも変わる。そのため、文書の今の本文と、今の本文へずらしてある文書のハンクを直に使う。ただし、ハンクが比べた
  /// 底が今の古い側の本文でなければ（古い側を入れ替える前）、並びは返さない——面に残っている並びは面自身の編集に付いて
  /// 動くので、返さなくても今の本文と食い違わない。
  var currentRows: (hunks: [LineHunk], newSide: DiffRows.Side)? {
    guard let document else {
      return revisionHunksSides == nil ? nil : (revisionHunks, newRevisionSide)
    }
    let side = DiffRows.Side(document.text)
    guard let oldSource else { return nil }
    // 丸ごとの置き換え（git が削除と追加に割るのと同じ形。古い側が無ければ全部の行の追加）。
    if oldReplacesWhole { return ([LineHunk(old: 0..<oldSide.lines, new: 0..<side.lines)], side) }
    guard document.hunksBase == oldSource else { return nil }
    return (document.hunks, side)
  }

  /// 新しい側が文書で、古い側が文書の底ではない（古い側がその版に無い、または出どころが `.documentReplacing` と答えた）。
  /// この場合、文書は底を持たず、ハンクもハンクの知らせも無いので、並びは両側の行の数だけで決まる——文書の本文が変われば
  /// diff が自分で並びを置き直す。
  var oldReplacesWhole: Bool { oldSource == .some(nil) || !oldIsBase }

  /// 見え方。版が無い側（`absent`）の面は、エディターの都合で持つ空の行に番号を描かない（存在しない行を番号付きで出さない）。
  private func look(
    _ presentation: SurfacePresentation, _ rows: SurfaceRows, absent: Bool
  ) -> SurfaceLook {
    var presentation = presentation
    presentation.numbersOwnLines = !absent
    return SurfaceLook(presentation: presentation, rows: rows, hunkLimit: Self.hunkLimit)
  }

  private func makeOldSurface() -> (any TextSurface)? {
    guard let old, let surface = surfaces.make() else { return nil }
    old.attach(surface)
    return surface
  }

  /// 初めて並びを置いたときに、最初の変更区間が見える位置へ送る——区間の上の文脈の行の上端（区間が先頭の行からなら、
  /// その前の差し込みの頭）から、区間の新しい側の終わりの行の上端（区間の削除行・詰め物を含む。末尾の区間なら並びの
  /// 終わり）までを、中央から、収まらなければ区間の先頭を上端に見せる。
  private func revealFirstChange(on surface: any TextSurface) {
    guard let first = currentRows?.hunks.first else { return }
    let lines = first.newLines
    surface.reveal(
      from: lines.lowerBound > 0 ? RowPosition(line: lines.lowerBound - 1) : .head(of: 0),
      to: RowPosition(line: lines.upperBound), policy: .center)
  }
}
