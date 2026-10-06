import CoreGraphics

/// 一覧の行のドラッグによる並べ替え。掴みの寿命（起こす・追う・捨てる・確定）をここで決め、View は
/// 行の `DragGesture` を `dragChanged` / `dragEnded` へ渡して、`drag` を描くだけにする。
extension TaskPaletteModel {
  /// onChanged。捨てた掴みの続きは無視し、別の掴みなら前の掴みを確定せずに新しく起こす。
  func dragChanged(_ taskID: Int, start: CGPoint, translation: CGFloat) {
    switch drag {
    case .dragging(var session) where session.start == start:
      session.translation = translation
      drag = .dragging(session)
    case .discarded(let discarded) where discarded == start:
      return
    default:
      beginDrag(taskID, start: start, translation: translation)
    }
  }

  /// onEnded。掴み始めと並びが変わっていなければ、落ちる位置へ 1 回だけ並べ替える。agent の変更を
  /// 付け直す `reconcile` より先に届くことがあるので、ここでも並びを確かめる。
  func dragEnded() {
    let ended = drag.session
    // 確定の後の付け直しが、自分の確定を「並びの変化」として捨てないよう、先に畳む。
    drag = .idle
    guard let session = ended, isIntact(session) else { return }
    place(from: session.from, to: session.target, among: session.siblings.map(\.id))
  }

  /// 掴み中に、掴んだタスクの欄の見えている並びと高さか、掴んだ行の上端が変わっていたら捨てる。
  func discardStaleDrag() {
    guard let session = drag.session, !isIntact(session) else { return }
    drag = .discarded(start: session.start)
  }

  /// クリックと同じ手順（編集を確定して一覧へ戻り、そのタスクを選ぶ）の後で掴む。掴めないタスク（完了・
  /// 見えていない）と選ぶ状態の間なら、この掴みの続きを無視する。
  private func beginDrag(_ taskID: Int, start: CGPoint, translation: CGFloat) {
    drag = .idle
    guard pick == nil, visibleSiblings(of: taskID) != nil else {
      drag = .discarded(start: start)
      return
    }
    tapRow(.task(taskID))
    guard let siblings = siblingRows(of: taskID),
      let from = siblings.firstIndex(where: { $0.id == taskID }),
      let top = rowTop(of: taskID)
    else {
      drag = .discarded(start: start)
      return
    }
    drag = .dragging(
      TaskPaletteDrag.Session(
        taskID: taskID, start: start, siblings: siblings, from: from, top: top,
        translation: translation))
  }

  /// 指と行がずれないことを守る: 落ちる位置の計算の土台（兄弟の並びと高さ）と、掴んだ行の上端が、掴み
  /// 始めと同じか。
  private func isIntact(_ session: TaskPaletteDrag.Session) -> Bool {
    siblingRows(of: session.taskID) == session.siblings && rowTop(of: session.taskID) == session.top
  }

  private func siblingRows(of taskID: Int) -> [TaskPaletteDrag.Sibling]? {
    guard let ids = visibleSiblings(of: taskID) else { return nil }
    let heights = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row -> (Int, CGFloat)? in
        guard case .task(let item) = row else { return nil }
        return (item.id, TaskPaletteRowMetrics.height(row))
      })
    return ids.compactMap { id in heights[id].map { TaskPaletteDrag.Sibling(id: id, height: $0) } }
  }

  private func rowTop(of taskID: Int) -> CGFloat? {
    guard let index = rows.firstIndex(where: { $0.selectableID == .task(taskID) }) else {
      return nil
    }
    return rows[..<index].reduce(0) { $0 + TaskPaletteRowMetrics.height($1) }
  }
}
