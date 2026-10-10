import AppKit
import OrbeEditorCore
import SwiftUI

/// サイドバーの一覧（エクスプローラーのツリー・検索結果の列）のつまみの決まり——見せる規則・つまみの幾何・色と時間。
/// 描く層は一覧ごとに違い（ツリーは SwiftUI の `sidebarScrollbar`、検索結果は AppKit の `RowListScrollbar`）、どちらも
/// この決まりに出来事を渡して、返った値を濃さの変化に写すだけ。トラックは描かず、掴めるのは見えているつまみだけ。
enum SidebarScrollbar {
  /// 見せる規則（時刻は外から渡す）。一覧の上にポインタがある間とつまみのドラッグ中は見え、位置が変わると現れて、
  /// 変わらなくなってから `hideDelay` 後に消え始める。ポインタが一覧から出た・ドラッグを離したときは、すぐ消え始める。
  /// 最初に受けた位置は変化に数えない（一覧を出しただけでは点かない）。全体や見えている長さの変化は受けない——
  /// 行が流れ込む間につまみが点滅し続けないため。
  struct Visibility {
    let hideDelay: Double
    private(set) var hovering = false
    private(set) var dragging = false
    private var position: CGFloat?
    private var lastChange = -Double.infinity
    /// ポインタが一覧から出た・ドラッグを離した時刻（それより前の位置の変化では見せ続けない）。
    private var lastRelease = -Double.infinity

    init(hideDelay: Double = Theme.Motion.editorScrollbarHideDelay) {
      self.hideDelay = hideDelay
    }

    mutating func hover(_ hovering: Bool, at time: Double) {
      if self.hovering && !hovering { lastRelease = time }
      self.hovering = hovering
    }

    mutating func drag(_ dragging: Bool, at time: Double) {
      if self.dragging && !dragging { lastRelease = time }
      self.dragging = dragging
    }

    mutating func scroll(to position: CGFloat, at time: Double) {
      if let last = self.position, last != position { lastChange = time }
      self.position = position
    }

    /// 時刻 `time` に見せるか。
    func isShown(at time: Double) -> Bool {
      hovering || dragging || isRecent(at: time)
    }

    /// 消え始める時刻（位置の変化だけで見えている間）。
    func hidesAt(_ time: Double) -> Double? {
      isRecent(at: time) && !hovering && !dragging ? lastChange + hideDelay : nil
    }

    private func isRecent(at time: Double) -> Bool {
      lastChange > lastRelease && time < lastChange + hideDelay
    }
  }

  /// 一覧の縦の量（pt）。
  struct Metrics {
    var position: CGFloat
    var total: CGFloat
    var visible: CGFloat

    /// つまみの幾何（一覧の全高がトラック）。位置は 0〜上限に丸める——弾みの間は位置が負や上限超えになり、
    /// `ScrollbarGeometry` は丸めないので、つまみがトラックの外へはみ出す。
    var geometry: ScrollbarGeometry {
      let position = min(max(0, position), max(0, total - visible))
      return ScrollbarGeometry(
        visible: visible, total: total, position: position, trackLength: visible)
    }
  }

  static var now: Double { ProcessInfo.processInfo.systemUptime }

  static func thumbColor(pointerOver: Bool, dragging: Bool) -> NSColor {
    if dragging { return Theme.Color.editorScrollbarSliderActive }
    return pointerOver ? Theme.Color.editorScrollbarSliderHover : Theme.Color.editorScrollbarSlider
  }

  /// 濃さの変化の長さ（現れる・消える）。
  static func fadeDuration(toShown shown: Bool, reduceMotion: Bool) -> Double {
    if reduceMotion { return 0 }
    return shown ? Theme.Motion.editorSliderFadeIn : Theme.Motion.editorScrollbarFadeOut
  }
}

extension View {
  /// ScrollView の中身全体に掛ける。中身に固定の `id` を付け、中身の枠（ScrollView の座標）をつまみへ知らせる。
  func sidebarScrollContent(id: some Hashable) -> some View {
    self.id(id).background {
      GeometryReader { geometry in
        Color.clear.preference(
          key: SidebarScrollContentFrame.self, value: geometry.frame(in: .scrollView))
      }
    }
  }

  /// ScrollView に掛け、サイドバーの一覧のつまみを重ねる（中身は `sidebarScrollContent(id: contentID)` を掛けておく）。
  func sidebarScrollbar(_ proxy: ScrollViewProxy, contentID: some Hashable) -> some View {
    modifier(SidebarScrollbarOverlay(proxy: proxy, contentID: AnyHashable(contentID)))
  }
}

private struct SidebarScrollContentFrame: PreferenceKey {
  static let defaultValue: CGRect? = nil
  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
    value = nextValue() ?? value
  }
}

/// SwiftUI の ScrollView に重ねるつまみ。つまみは当たりを持たない見た目だけの部品で、ポインタは ScrollView 自身が受ける
/// ——ホバーの位置で「見えているつまみの上か」を決め、その間とドラッグ中だけ ScrollView のドラッグを行より優先させる。
/// 重ねた部品に当たりを持たせると、その上のホイールが ScrollView に届かないため。量はこの修飾子の状態に受ける——
/// 持ち主の body（行の `ForEach`）をスクロールで評価し直さない。送るのは `scrollTo` に中身全体と比 f の anchor を渡す。
/// anchor は対象と ScrollView の比が同じ点どうしを揃える契約なので、位置は f ×（全体 − 見えている長さ）に写り、pt 単位で
/// 連続に送れる。
private struct SidebarScrollbarOverlay: ViewModifier {
  let proxy: ScrollViewProxy
  let contentID: AnyHashable
  @State private var content: CGRect?
  @State private var size: CGSize = .zero
  @State private var visibility = SidebarScrollbar.Visibility()
  @State private var shown = false
  @State private var hidesAt: Double?
  /// ポインタの最後の位置（一覧の外なら nil）。つまみの上かは、つまみが動くたびにここから計算し直す——止まったポインタの
  /// 下へつまみが滑ってきても判定がずれない。
  @State private var pointer: CGPoint?
  /// 押したときの幾何（ドラッグの起点）。
  @State private var grab: ScrollbarGeometry?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let space = "sidebarScrollbar"

  private var metrics: SidebarScrollbar.Metrics {
    SidebarScrollbar.Metrics(
      position: -(content?.minY ?? 0), total: content?.height ?? 0, visible: size.height)
  }

  private var thumbRect: CGRect {
    let geometry = metrics.geometry
    guard geometry.isNeeded else { return .null }
    let width = Theme.Layout.editorSidebarScrollbar
    return CGRect(
      x: size.width - width, y: geometry.sliderPosition, width: width,
      height: geometry.sliderLength)
  }

  private var pointerOverThumb: Bool {
    pointer.map(thumbRect.contains) ?? false
  }

  func body(content view: Content) -> some View {
    view
      .onPreferenceChange(SidebarScrollContentFrame.self) { frame in
        guard let frame else { return }
        content = frame
        visibility.scroll(to: -frame.minY, at: SidebarScrollbar.now)
        refresh()
      }
      .onGeometryChange(for: CGSize.self, of: \.size) { size in
        self.size = size
        refresh()
      }
      .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
        switch phase {
        case .active(let location): point(at: location)
        case .ended: point(at: nil)
        }
      }
      .highPriorityGesture(
        drag(from: metrics.geometry),
        including: grab != nil || (shown && pointerOverThumb) ? .all : .subviews
      )
      .overlay(alignment: .topTrailing) { thumb }
      .coordinateSpace(.named(Self.space))
      .task(id: hidesAt) {
        guard let hidesAt else { return }
        do {
          try await Task.sleep(for: .seconds(max(0, hidesAt - SidebarScrollbar.now)))
        } catch { return }
        refresh()
      }
  }

  @ViewBuilder private var thumb: some View {
    let geometry = metrics.geometry
    if geometry.isNeeded {
      Rectangle()
        .fill(
          Color(
            nsColor: SidebarScrollbar.thumbColor(
              pointerOver: pointerOverThumb, dragging: grab != nil))
        )
        .frame(width: Theme.Layout.editorSidebarScrollbar, height: geometry.sliderLength)
        .offset(y: geometry.sliderPosition)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
    }
  }

  /// ポインタが一覧の `location` に居る（nil は外）。
  private func point(at location: CGPoint?) {
    pointer = location
    let inside = location != nil
    guard inside != visibility.hovering else { return }
    visibility.hover(inside, at: SidebarScrollbar.now)
    refresh()
  }

  private func drag(from geometry: ScrollbarGeometry) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .onChanged { value in
        if grab == nil {
          grab = geometry
          visibility.drag(true, at: SidebarScrollbar.now)
          refresh()
        }
        guard let grab else { return }
        let position = grab.position(afterDragging: value.translation.height)
        proxy.scrollTo(
          contentID, anchor: UnitPoint(x: 0, y: position / max(1, grab.maxPosition)))
      }
      .onEnded { value in
        grab = nil
        visibility.drag(false, at: SidebarScrollbar.now)
        // ドラッグ中はホバーが届かないことがあるので、離した位置で一覧の内外を決め直す。
        point(at: CGRect(origin: .zero, size: size).contains(value.location) ? value.location : nil)
        refresh()
      }
  }

  private func refresh() {
    let now = SidebarScrollbar.now
    let next = visibility.isShown(at: now) && metrics.geometry.isNeeded
    if next != shown {
      let duration = SidebarScrollbar.fadeDuration(toShown: next, reduceMotion: reduceMotion)
      withAnimation(.linear(duration: duration)) { shown = next }
    }
    hidesAt = visibility.hidesAt(now)
  }
}
