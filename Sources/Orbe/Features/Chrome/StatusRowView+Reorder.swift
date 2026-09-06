import SwiftUI

/// 閾値到達後の掴み 1 回ぶん。掴んだもの（セルまたはセグメント）・掴み開始時に固定した幾何・移動量・
/// 挿入先を持つ。掴み中にタブ集合／連構造が変わったら丸ごと破棄し、破棄後の onEnded は何も commit しない。
struct DragSession {
  enum Source: Equatable {
    /// セル掴み。値は平坦なタブ index。
    case tab(Int)
    /// セグメント掴み。値はセグメント index（`TabStrip.segments` の位置）。
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

  /// セル掴みなら、そのセルを含むセグメント。セグメント掴みは nil。
  var cellSegment: StatusTabLayout.SegmentFrame? {
    guard case .tab(let i) = source else { return nil }
    return geometry.segment(containing: i)
  }
}

/// 掴み状態の遷移（起こす・追従・破棄・確定）。View はここが返す結果を描き、遷移の判断を持たない。
struct DragState {
  private(set) var session: DragSession?
  /// タブ集合／連構造の変化で破棄した掴みの startLocation。同じ掴みの後続 onChanged が新しい session を
  /// 起こさないためのしるし（別の掴みは startLocation が違う）。
  private(set) var discardedStart: CGPoint?

  /// onChanged。破棄済みの掴みの続きなら無視し、それ以外は session を起こす／追従させる。
  mutating func track(
    source: DragSession.Source, start: CGPoint, translation: CGFloat,
    geometry: @autoclosure () -> StatusTabLayout.Geometry
  ) {
    if let discardedStart {
      guard discardedStart != start else { return }
      self.discardedStart = nil
    }
    var next = session ?? DragSession(source: source, start: start, geometry: geometry())
    next.translation = translation
    next.dropIndex = StatusRowView.dropIndex(next)
    session = next
  }

  /// onEnded。commit すべき session を返して状態を畳む。破棄後は nil（何も commit しない）。
  mutating func end() -> DragSession? {
    discardedStart = nil
    defer { session = nil }
    return session
  }

  /// タブ集合／連構造が変わった。掴み中なら破棄する（index が総崩れするため継続は不正で、掴んでいた
  /// View は構造ごと消えるので onEnded は来ない）。
  mutating func discard() {
    guard let session else { return }
    discardedStart = session.start
    self.session = nil
  }
}

/// タブ行のドラッグ&ドロップ並び替え（同一 workspace 内・commit-on-drop）。掴み中はデータを変異させず、
/// 移動量から挿入先 index を出してキャレットで示し、指を離した瞬間に 1 回だけ `onReorder`／
/// `onReorderSegment` を呼ぶ。セルは自セグメントの中だけ（キャレットも追従もセグメント端で止まる）、
/// セグメントはセグメント境界へ。
extension StatusRowView {
  /// `source` の掴み。閾値超過でドラッグに確定し、移動量から挿入先を出してキャレットを更新する。
  /// no-op（同位置）で離しても store 側のガードが弾く。座標空間は `.global`——既定の `.local` だと
  /// startLocation がセルごとの相対座標になり、隣のセルの同じ場所を掴んだ別の掴みと一致しうる。
  func dragGesture(_ source: DragSession.Source, widths: [CGFloat], segments: [Range<Int>])
    -> some Gesture
  {
    DragGesture(minimumDistance: dragActivation, coordinateSpace: .global)
      .onChanged { value in
        dragState.track(
          source: source, start: value.startLocation, translation: value.translation.width,
          geometry: StatusTabLayout.geometry(widths: widths, segments: segments))
      }
      .onEnded { _ in
        guard let session = dragState.end() else { return }
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
  static func dropIndex(_ session: DragSession) -> Int {
    let geo = session.geometry
    switch session.source {
    case .tab(let i):
      let r = geo.segment(containing: i).range
      let pointer = geo.cells[i].midX + session.translation
      return r.lowerBound + r.filter { geo.cells[$0].midX < pointer }.count
    case .segment(let s):
      let pointer = geo.segments[s].midX + session.translation
      let k = geo.segments.filter { $0.midX < pointer }.count
      return k < geo.segments.count ? geo.segments[k].range.lowerBound : geo.count
    }
  }

  /// 掴んだセル i の表示 offset。セルが器（自セグメントのセル域）の外へ出ないよう translation をクランプする。
  static func cellOffset(_ session: DragSession) -> CGFloat {
    guard case .tab(let i) = session.source, let seg = session.cellSegment else { return 0 }
    let geo = session.geometry
    let first = geo.cells[seg.range.lowerBound]
    let last = geo.cells[seg.range.upperBound - 1]
    let cell = geo.cells[i]
    return min(max(session.translation, first.x - cell.x), last.maxX - cell.maxX)
  }

  /// 挿入キャレット（幅 2）の左端 x。セル掴みは連内のセル境界、セグメント掴みは隙間の中央に中央合わせする。
  static func insertionCaretX(_ session: DragSession) -> CGFloat {
    let geo = session.geometry
    let j = session.dropIndex
    let line: CGFloat
    if let seg = session.cellSegment {
      line = j < seg.range.upperBound ? geo.cells[j].x : seg.maxX
    } else if let k = geo.segments.firstIndex(where: { $0.range.lowerBound == j }) {
      line = geo.segments[k].x - Chrome.tabGap / 2
    } else {
      line = geo.rowEnd + Chrome.tabGap / 2
    }
    return max(0, line - 1)
  }
}
