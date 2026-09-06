import SwiftUI

/// 閾値到達後の掴み 1 回ぶん。掴んだもの（セルまたはセグメント）・掴み開始時に固定した幾何・移動量・
/// 挿入先を持つ。掴み中にタブ集合／順序が変わったら丸ごと破棄し、破棄後の onEnded は何も commit しない。
struct DragSession {
  enum Source: Equatable {
    case tab(Int)
    case segment(Int)
  }
  let source: Source
  /// 掴み開始時の startLocation（破棄後、同じ掴みの後続 onChanged を見分ける）。
  let start: CGPoint
  /// 掴み開始時の幾何を固定する（挿入先/キャレット計算の基準）。掴み中にグリフ出現等で live な幅が動いても
  /// 基準がぶれず、確定ドロップが 1 個分ずれない。commit-on-drop のレイアウト凍結と整合。
  let geometry: StatusTabLayout.Geometry
  /// 掴み開始からの水平移動量。
  var translation: CGFloat = 0
  /// タブ挿入 index（挿入前基準・0…count）。セグメント掴みでも境界をタブ index で表す。
  var dropIndex = 0
}

/// タブ行のドラッグ&ドロップ並び替え（同一 workspace 内・commit-on-drop）。掴み中はデータを変異させず、
/// 移動量から挿入先 index を出してキャレットで示し、指を離した瞬間に 1 回だけ `onReorder`／
/// `onReorderSegment` を呼ぶ。セルは自セグメントの中だけ（キャレットも追従もセグメント端で止まる）、
/// セグメントはセグメント境界へ。
extension StatusRowView {
  /// `source` の掴み。閾値超過でドラッグに確定し、移動量から挿入先を出してキャレットを更新する。
  /// no-op（同位置）で離しても store 側のガードが弾く。
  func dragGesture(_ source: DragSession.Source, widths: [CGFloat], segments: [Range<Int>])
    -> some Gesture
  {
    DragGesture(minimumDistance: dragActivation)
      .onChanged { value in
        if let discarded = discardedDragStart {
          guard discarded != value.startLocation else { return }
          discardedDragStart = nil
        }
        var session =
          drag
          ?? DragSession(
            source: source, start: value.startLocation,
            geometry: StatusTabLayout.geometry(widths: widths, segments: segments))
        session.translation = value.translation.width
        session.dropIndex = dropIndex(session)
        drag = session
      }
      .onEnded { _ in
        discardedDragStart = nil
        guard let session = drag else { return }
        drag = nil
        switch session.source {
        case .tab(let i):
          model.onReorder(i, session.dropIndex)
        case .segment(let s):
          model.onReorderSegment(session.geometry.segments[s].range.lowerBound, session.dropIndex)
        }
      }
  }

  /// 挿入先 index（挿入前基準）。掴み開始時に固定した中心 x とポインタ x（中心＋translation）を比べ、
  /// 中心を追い越した数を数える（自分の中心も数える＝store の挿入前 index 基準と同じ）。
  /// セル掴みは自セグメントの中（lowerBound…upperBound）、セグメント掴みはセグメント境界。
  func dropIndex(_ session: DragSession) -> Int {
    let geo = session.geometry
    switch session.source {
    case .tab(let i):
      let r = geo.segments.first { $0.range.contains(i) }?.range ?? i..<(i + 1)
      let pointer = geo.cells[i].midX + session.translation
      return r.lowerBound + r.filter { geo.cells[$0].midX < pointer }.count
    case .segment(let s):
      let pointer = geo.segments[s].midX + session.translation
      let k = geo.segments.filter { $0.midX < pointer }.count
      return k < geo.segments.count ? geo.segments[k].range.lowerBound : geo.count
    }
  }

  /// 掴んだセル i の表示 offset。セルが器（自セグメントのセル域）の外へ出ないよう translation をクランプする。
  func cellOffset(_ session: DragSession) -> CGFloat {
    guard case .tab(let i) = session.source else { return 0 }
    let geo = session.geometry
    guard let seg = geo.segments.first(where: { $0.range.contains(i) }) else { return 0 }
    let first = geo.cells[seg.range.lowerBound]
    let last = geo.cells[seg.range.upperBound - 1]
    let cell = geo.cells[i]
    return min(max(session.translation, first.x - cell.x), last.maxX - cell.maxX)
  }

  /// 挿入キャレット（幅 2）の左端 x。セル掴みは連内のセル境界、セグメント掴みは隙間の中央に中央合わせする。
  func insertionCaretX(_ session: DragSession) -> CGFloat {
    let geo = session.geometry
    let j = session.dropIndex
    let line: CGFloat
    switch session.source {
    case .tab(let i):
      let seg = geo.segments.first { $0.range.contains(i) }
      line = j < (seg?.range.upperBound ?? geo.count) ? geo.cells[j].x : seg?.maxX ?? geo.rowEnd
    case .segment:
      if let k = geo.segments.firstIndex(where: { $0.range.lowerBound == j }) {
        line = geo.segments[k].x - Chrome.tabGap / 2
      } else {
        line = geo.rowEnd + Chrome.tabGap / 2
      }
    }
    return max(0, line - 1)
  }
}
