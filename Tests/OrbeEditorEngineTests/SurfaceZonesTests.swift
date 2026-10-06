import AppKit
import OrbeEditorCore
import XCTest

@testable import OrbeEditorEngine

/// 区画（載せる側の view を置く差し込み）——面が本文の区画の幅で測った高さ・本文と同じ位置への置き方・幅や中身の変化での
/// 測り直し・当たりの落ち方・上端の影と横スクロールバーとの重ね順、刻みごとの位置の封じ。壊れると、PR のスレッドが本文の
/// 行に重なる・ずれて動く・幅を変えても高さが中身に合わない・スレッドの上でクリックやスクロールが効かない。
@MainActor
final class SurfaceZonesTests: EngineTestCase {
  private let size = CGSize(width: 600, height: 400)

  /// ミニマップを出さない面を窓に載せる（`count` 行）。
  private func hostedRows(_ count: Int = 80, long: Bool = false) throws -> Opened {
    let opened = try open(rows(count, width: long ? 400 : 10), size: size)
    opened.surface.setPresentation(SurfacePresentation(showsMinimap: false))
    _ = host(opened, size: size)
    return opened
  }

  private func zone(_ view: NSView, at line: Int) -> SurfaceRows {
    SurfaceRows(insertions: [RowInsertion(line: line, content: .zone(view))])
  }

  /// 区画の高さは view を本文の区画の幅で測った高さで、view は本文と同じ位置（並びの y − スクロールの位置）に、本文の区画の
  /// 幅いっぱいで置かれる。下の文書の行はその高さだけ下がる。
  func testAZoneIsMeasuredAndPlacedWithTheText() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let view = FixedZone(height: 50)
    surface.setRows(zone(view, at: 4))
    surface.flush()
    XCTAssertEqual(surface.rows.heights, [50])
    XCTAssertEqual(surface.rows.y(ofLine: 4), 4 * 18 + 50)
    XCTAssertFalse(view.isHidden)
    XCTAssertEqual(view.frame.minY, surface.rows.top(ofBlock: 0))
    XCTAssertEqual(view.frame.width, surface.surfaceLayout.text.width)
    XCTAssertEqual(view.frame.height, 50)
    let container = try XCTUnwrap(view.superview)
    XCTAssertEqual(container.frame.minX, surface.surfaceLayout.text.minX)
    XCTAssertEqual(container.frame.minY, surface.config.topInset)
    surface.scroll(toFirstLine: 2.5)
    surface.flush()
    XCTAssertEqual(view.frame.minY, surface.rows.top(ofBlock: 0) - 2.5 * 18, accuracy: 1e-9)
    surface.scroll(toFirstLine: 60)
    surface.flush()
    XCTAssertTrue(view.isHidden, "見えていない区画は隠す")
    surface.setRows(SurfaceRows())
    XCTAssertNil(view.superview, "外れた view は面から外す")
  }

  /// 載せる側が測り直すと言えば測り直し、見えている先頭の文書の行より上の区画が伸びても、その行の画面上の位置は変わらない。
  func testRemeasuringAZoneAboveKeepsTheFirstVisibleLine() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let view = FixedZone(height: 40)
    surface.setRows(zone(view, at: 5))
    surface.scroll(toFirstLine: 20)
    surface.flush()
    let offset = surface.scrollPosition.y - surface.rows.y(ofLine: 20)
    view.height = 90
    surface.remeasureZone(view)
    surface.flush()
    XCTAssertEqual(surface.rows.heights, [90])
    XCTAssertEqual(surface.scrollPosition.y - surface.rows.y(ofLine: 20), offset, accuracy: 1e-9)
    surface.remeasureZone(FixedZone(height: 10))
    XCTAssertEqual(surface.rows.heights, [90], "置いていない view は何もしない")
  }

  /// 本文の区画の幅が変われば（窓の大きさ・行番号の桁）測り直す。
  func testAZoneIsRemeasuredWhenTheTextWidthChanges() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let view = WrappingZone()
    surface.setRows(zone(view, at: 3))
    let wide = surface.rows.heights[0]
    XCTAssertEqual(wide, WrappingZone.height(width: surface.surfaceLayout.text.width))
    surface.viewStateDidChange(size: CGSize(width: 300, height: 400), scale: 2, visible: false)
    XCTAssertEqual(
      surface.rows.heights[0], WrappingZone.height(width: surface.surfaceLayout.text.width))
    XCTAssertGreaterThan(surface.rows.heights[0], wide, "狭くなれば高くなる")
  }

  /// 区画の view が受けない点は面へ落ち、次の文書の行の行頭に当たる。区画の外の入れ物の点は面が受ける。
  func testPointsOverAZoneFallThroughToTheSurface() throws {
    let opened = try hostedRows()
    let surface = opened.surface
    let view = FixedZone(height: 50)
    surface.setRows(zone(view, at: 4))
    surface.flush()
    let face = surface.textView
    let inside = CGPoint(
      x: surface.surfaceLayout.text.minX + 20,
      y: surface.config.topInset + CGFloat(surface.rows.top(ofBlock: 0)) + 10)
    XCTAssertTrue(face.hitTest(face.convert(inside, to: face.superview)) === view)
    let outside = CGPoint(x: inside.x, y: surface.config.topInset + 1.5 * 18)
    XCTAssertTrue(face.hitTest(face.convert(outside, to: face.superview)) === face)
    XCTAssertEqual(surface.hit(inside)?.offset, opened.document.text.lineStart(4))
    XCTAssertNil(surface.character(at: inside))
  }

  /// 区画のある面では上端の影を Metal で描かず、区画の上の view が描く（区画が影を覆わない）。横スクロールバーが出ていれば、
  /// 入れ物はその帯を除く。
  func testTheTopShadowAndTheHorizontalScrollbarStayAboveZones() throws {
    let opened = try hostedRows(long: true)
    let surface = opened.surface
    surface.scroll(toFirstLine: 3)
    _ = surface.snapshot()
    let white = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
    let plain = try pixelShot(opened, background: white)
    let x = surface.surfaceLayout.text.minX + 100
    XCTAssertLessThan(plain.rgb(x, 0.5)[0], 250, "前提: 区画の無い面は Metal が影を描く")
    let view = FixedZone(height: 50)
    surface.setRows(zone(view, at: 30))
    surface.flush()
    let zoned = try pixelShot(opened, background: white)
    XCTAssertEqual(zoned.rgb(x, 0.5), [255, 255, 255], "区画のある面の Metal は影を描かない")
    let container = try XCTUnwrap(view.superview)
    let shadow = try XCTUnwrap(
      surface.textView.subviews.first { $0 is ZoneShadowView })
    XCTAssertFalse(shadow.isHidden, "影は区画の上の view が描く")
    XCTAssertTrue(
      surface.textView.subviews.firstIndex(of: shadow)! > surface.textView.subviews.firstIndex(
        of: container)!, "影は入れ物の上")
    XCTAssertGreaterThan(surface.scrollState().limits.maximum.x, 0, "前提: 横に続く")
    XCTAssertEqual(container.frame.maxY, surface.surfaceLayout.horizontalScrollbar.minY)
  }

  /// 封じる面では、同じ刻みに描画スレッドと main が同じ縦の位置と「戻りの途中か」を読み、封じた後に届いた指の出来事は次の
  /// 刻みに出る。main が置けば封じを解く。封じない面は、いつも今の位置。
  func testTheSameTickReadsTheSamePosition() {
    let box = ScrollBox()
    box.updateLimits(
      LimitsUpdate(bottom: 999 * 10, lineHeight: 10, viewport: SIMD2(100, 100), cell: 7))
    let period = 1.0 / 120
    let tick = 100 * period
    box.setSealing(true)
    let sealed = box.sealed(at: tick, period: period)
    box.apply(ScrollInput(timestamp: tick, delta: .zero, precise: true, phase: .began))
    box.apply(
      ScrollInput(timestamp: tick + 0.001, delta: SIMD2(0, -40), precise: true, phase: .changed))
    XCTAssertEqual(
      box.frame(at: tick + 0.001, period: period, material: 0).position.y, sealed.position.y,
      "同じ刻みは封じた位置")
    XCTAssertEqual(box.frame(at: tick + period, period: period, material: 0).position.y, 40)
    XCTAssertEqual(box.sealed(at: tick + period, period: period).position.y, 40, "main も同じ")
    box.place(SIMD2(0, 70))
    XCTAssertEqual(box.sealed(at: tick + period, period: period).position.y, 70, "置けば解く")
    box.setSealing(false)
    box.apply(
      ScrollInput(timestamp: tick + 0.01, delta: SIMD2(0, -10), precise: true, phase: .changed))
    XCTAssertEqual(box.frame(at: tick + period, period: period, material: 0).position.y, 80)
  }
}

/// 高さの決まった区画の view（高さの制約）。
private final class FixedZone: NSView {
  private var constraint: NSLayoutConstraint?

  var height: CGFloat {
    get { constraint?.constant ?? 0 }
    set { constraint?.constant = newValue }
  }

  init(height: CGFloat) {
    super.init(frame: .zero)
    constraint = heightAnchor.constraint(equalToConstant: height)
    constraint?.isActive = true
  }

  required init?(coder: NSCoder) { fatalError("not supported") }
}

/// 幅で高さが変わる区画の view（折り返す文の代わり。高さ = 12000 / 幅）。
private final class WrappingZone: NSView {
  static func height(width: CGFloat) -> Double { Double((12_000 / width).rounded(.up)) }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(Self.height(width: bounds.width)))
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { invalidateIntrinsicContentSize() }
  }
}
