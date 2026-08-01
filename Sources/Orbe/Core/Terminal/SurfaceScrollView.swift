import AppKit

/// SurfaceView を NSScrollView でラップし、macOS ネイティブの overlay スクロールバーを与える。
///
/// 本家 macOS Ghostty の `SurfaceScrollView` のアルゴリズムを Orbe の C API 直叩きスタイルに移植したもの。
///
/// このインスタンスの同一性は分割ツリーの変更（分割/クローズ/workspace 切替）をまたいで
/// 保たれねばならない（再生成すると scrollback 状態が失われる・cf. ghostty-org/ghostty#9444）。
/// ゆえに分割ツリーは AppKit のまま据え置く（`TerminalController` 参照）。
///
/// ## 座標系
/// AppKit は +Y 上向き（原点 = 左下）、ターミナルは概念上 +Y 下向き（row 0 が上）。
/// 行 offset とピクセル位置の変換でこの反転を吸収する。
///
/// ## 構成
/// - `scrollView`: スクロールバーの描画・挙動を司る最外殻の NSScrollView。
/// - `documentView`: 高さが scrollback 総量（ピクセル）を表す空の NSView。
/// - `surfaceView`: 実際の Ghostty レンダラ。可視矩形を埋める位置に置く。
final class SurfaceScrollView: NSView {
  private let scrollView = NSScrollView()
  private let documentView = NSView()
  let surfaceView: SurfaceView
  private var observers: [NSObjectProtocol] = []
  private var isLiveScrolling = false

  /// scroll_to_row で最後に送った行。ドラッグで同じ行に留まる間の冗長送信を防ぐ。
  private var lastSentRow: Int?

  init(surfaceView: SurfaceView) {
    self.surfaceView = surfaceView
    super.init(frame: .zero)

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = false
    scrollView.usesPredominantAxisScrolling = true
    // 常に overlay スタイル（autohide に任せる。config は持たない）。
    scrollView.scrollerStyle = .overlay
    scrollView.drawsBackground = false
    // 非 overlay スクローラの背後に surface 背景を描けるようクリップしない。
    scrollView.contentView.clipsToBounds = false

    documentView.frame = .zero
    scrollView.documentView = documentView
    // surface は documentView の子。スクロールに追従させ viewport だけ描画させる。
    documentView.addSubview(surfaceView)

    addSubview(scrollView)

    // libghostty からの scrollbar / cell_size 更新を受けて同期する。
    surfaceView.onScrollbarUpdate = { [weak self] in self?.synchronizeScrollView() }

    // NSClipView の bounds 変化（スクロール）で surface 位置を追従させる。
    // 出典: https://christiantietze.de/posts/2018/07/synchronize-nsscrollview/
    scrollView.contentView.postsBoundsChangedNotifications = true
    observe(NSView.boundsDidChangeNotification, scrollView.contentView) { [weak self] in
      self?.synchronizeSurfaceView()
    }
    observe(NSScrollView.willStartLiveScrollNotification, scrollView) { [weak self] in
      self?.isLiveScrolling = true
    }
    observe(NSScrollView.didEndLiveScrollNotification, scrollView) { [weak self] in
      self?.isLiveScrolling = false
    }
    observe(NSScrollView.didLiveScrollNotification, scrollView) { [weak self] in
      self?.handleLiveScroll()
    }
    observe(NSScroller.preferredScrollerStyleDidChangeNotification, nil) { [weak self] in
      self?.scrollView.scrollerStyle = .overlay
    }
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

  private func observe(_ name: Notification.Name, _ object: Any?, _ body: @escaping () -> Void) {
    observers.append(
      NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
        body()
      })
  }

  override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
    surfaceView.frame.size = scrollView.bounds.size
    documentView.frame.size.width = scrollView.bounds.width
    synchronizeScrollView()
    synchronizeSurfaceView()
  }

  // MARK: - 同期

  /// surface を現在の可視矩形を埋める位置に置く（レンダラは画面分だけ描けばよい）。
  private func synchronizeSurfaceView() {
    surfaceView.frame.origin = scrollView.contentView.documentVisibleRect.origin
  }

  /// documentView の高さを scrollback 総量に合わせ、scroll 位置を offset に同期する。
  private func synchronizeScrollView() {
    documentView.frame.size.height = documentHeight()

    // ライブスクロール中はユーザーのドラッグと競合しないよう位置を動かさない。
    if !isLiveScrolling {
      let cellHeight = surfaceView.cellSize.height
      if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
        // 反転: terminal offset は上から、AppKit 位置は下から。
        let offsetY = CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
        lastSentRow = scrollbar.offset
      }
    }

    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  // MARK: - ドラッグ → core

  /// ライブスクロール（ユーザーがバーをドラッグ）を行に変換して core へ送る。冗長送信は抑制する。
  private func handleLiveScroll() {
    let cellHeight = surfaceView.cellSize.height
    guard cellHeight > 0 else { return }

    // AppKit は +Y 上向きなので下端から計算する。
    let visibleRect = scrollView.contentView.documentVisibleRect
    let scrollOffset = documentView.frame.height - visibleRect.origin.y - visibleRect.height
    let row = Int(scrollOffset / cellHeight)

    guard row != lastSentRow else { return }
    lastSentRow = row
    surfaceView.scrollToRow(row)
  }

  // MARK: - 計算

  /// scrollbar 状態から documentView の高さを求める。
  private func documentHeight() -> CGFloat {
    let contentHeight = scrollView.contentSize.height
    let cellHeight = surfaceView.cellSize.height
    if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
      // documentView の上下 padding を content view と揃えないと surface と整列がずれる。
      let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
      let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
      return documentGridHeight + padding
    }
    return contentHeight
  }

  // MARK: - マウス（legacy スタイルでのドラッグ用に scroller を点滅させる）

  override func mouseMoved(with event: NSEvent) {
    guard NSScroller.preferredScrollerStyle == .legacy else { return }
    scrollView.flashScrollers()
  }

  override func updateTrackingAreas() {
    trackingAreas.forEach { removeTrackingArea($0) }
    super.updateTrackingAreas()
    guard let scroller = scrollView.verticalScroller else { return }
    addTrackingArea(
      NSTrackingArea(
        rect: convert(scroller.bounds, from: scroller),
        options: [.mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil))
  }
}
