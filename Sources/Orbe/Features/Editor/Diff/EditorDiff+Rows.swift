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
      var rows = DiffRows.inline(hunks, new: newSide)
      rows.source = old
      look(DiffStyle.inline, rows, absent: newSide.isAbsent).apply(to: surface, document: document)
    case .side:
      let rows = DiffRows.side(hunks, old: oldSide, new: newSide)
      let left = oldSurface ?? makeOldSurface()
      if let left {
        look(DiffStyle.side, rows.left, absent: oldSide.isAbsent).apply(to: left, document: nil)
      }
      look(DiffStyle.side, rows.right, absent: newSide.isAbsent)
        .apply(to: surface, document: document)
      if let left, oldSurface == nil {
        if placement == .placed { carryTop(to: surface) }
        oldSurface = left
        surface.shareScroll(with: left)
        surfacesChanged = true
      }
    }
    placeFirstView(on: surface)
  }

  /// 面に初めて見せる位置へ送る——位置を決めた後に作り直した面なら前の面で先頭に見えていた所、まだなら、開いた時点に
  /// 追いついた並びで 1 回だけ最初の変更区間（無ければ送らない）。どちらも見えている高さで決まる位置なので、面がまだ大きさを
  /// 持たない（本体に置いた直後の配置の前）なら送らず、大きさが決まって見えている範囲が変わったとき（`viewportDidChange`）に
  /// 送る。
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
    }
  }

  /// 並びが開いた時点に追いついている——開いた後の取り直しが済んだ後の状態から作られている。作業ツリー: 文書のハンクが
  /// 今の index の本文に対する今の版の結果。ステージ済み: 済んだ後に頼んだ行差分が届いた。
  var isCaughtUp: Bool {
    guard resolvedAfterCatchUp, content == .ready, currentRows != nil else { return false }
    switch id.kind {
    case .staged: return !stagedPending
    case .workingTree:
      guard let document,
        case .text(let base)? = files.state(of: RootFiles.Version(path: id.path, revision: .index))
      else { return true }
      return document.hunksAreCurrent && document.hunksBase == base
    }
  }

  /// 作り直した新しい側の面で、前の面で先頭に見えていた所を先頭に置く。
  private func carryTop(to surface: any TextSurface) {
    guard let carried, let hunks = currentRows?.hunks else { return }
    self.carried = nil
    switch carried {
    case .anchor(let anchor):
      surface.scroll(to: DiffRows.position(of: anchor, hunks, side: presented == .side))
    case .position(let position):
      surface.scroll(to: position)
    }
  }

  /// 今の古い側と新しい側の本文に対して正しいと分かっている行差分と、新しい側の大きさ。作業ツリー diff の新しい側の文書は
  /// 外の書き換えでいつでも変わるので、文書の今の本文と、文書のハンク（今の本文へずらしてある）を直に使い、ハンクが比べた底
  /// が今の古い側でなければ（古い側を入れ替える前）並べない——面に残っている並びは面自身の編集に付いて動くので、今の本文と
  /// 食い違わない。
  var currentRows: (hunks: [LineHunk], newSide: DiffRows.Side)? {
    guard let document else { return (revisionHunks, newRevisionSide) }
    let side = DiffRows.Side(document.text)
    guard let oldSource else { return nil }
    guard let base = oldSource else {
      return (DiffRows.hunks(old: nil, new: document.text, limit: Self.hunkLimit), side)
    }
    // サブモジュールからファイルへ置き換えた行——古い側は文書の底ではないので、丸ごとの置き換え（git が削除と追加に割るのと
    // 同じ形）。
    if oldIsSubmodule { return ([LineHunk(old: 0..<oldSide.lines, new: 0..<side.lines)], side) }
    guard document.hunksBase == base else { return nil }
    return (document.hunks, side)
  }

  /// 見え方。版が無い側（`absent`）の面は、エディターの都合で持つ空の行に番号を描かない（存在しない行を番号付きで出さない）。
  private func look(
    _ presentation: SurfacePresentation, _ rows: SurfaceRows, absent: Bool
  ) -> SurfaceLook {
    var presentation = presentation
    presentation.numbersOwnLines = !absent
    return SurfaceLook(
      presentation: presentation, rows: rows, isEditable: false, hunkLimit: Self.hunkLimit)
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
