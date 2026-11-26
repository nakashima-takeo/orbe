import CoreGraphics
import XCTest

@testable import Orbe

/// 右シート左端ドラッグの幅追従・上下限クランプ・全面吸着・右投げ閉じ・直前通常域比率の記憶・
/// 狭幅ウィンドウでの幅算出を守る。
///
/// 壊れると何が起きるか。ドラッグで全面吸着や右投げ閉じができなくなる、閉じたり全面化したあとに
/// 右シートへ戻すと直前の幅が失われて極端な幅になる、あるいは狭いウィンドウでシートが窓幅を超えて破綻する。
final class BrowserResizeSessionTests: OrbeTestCase {
  /// 通常域では上下限（28%〜84%）で追従し、全面吸着（86% 超）や右投げ閉じ（240pt 未満）へ入っても
  /// 直前の通常域比率を保持したまま確定結果へ渡す。
  func testDraggingTracksClampedRatioAndPreservesNormalRatioAcrossSnapZones() {
    let width: CGFloat = 1000
    var session = BrowserResizeSession(
      initialRatio: BrowserResizeSession.defaultRatio, containerWidth: width)

    let normal = session.update(pointerX: 400, containerWidth: width)
    XCTAssertEqual(normal, .normal(width: 600, ratio: 0.60))
    XCTAssertEqual(normal.badgeKind, .percent(60))
    XCTAssertEqual(session.commit(), .keepSheet(ratio: 0.60))

    // 上限 84%〜吸着閾値 86% の間は上限 84% に留め、まだ全面吸着しない。
    let capped = session.update(pointerX: 150, containerWidth: width)
    XCTAssertEqual(capped, .normal(width: 840, ratio: BrowserResizeSession.maxRatio))
    XCTAssertEqual(session.preservedRatio, BrowserResizeSession.maxRatio)

    // 86% を超えると全面吸着し、直前の通常域比率を壊さない。
    let snapFull = session.update(pointerX: 130, containerWidth: width)
    XCTAssertEqual(snapFull, .snapFull(width: width))
    XCTAssertEqual(snapFull.badgeKind, .snapFull)
    XCTAssertEqual(session.commit(), .snapFull(preservedRatio: BrowserResizeSession.maxRatio))

    // 通常域へ引き戻して 45% に合わせた後、右投げ閉じ域（240pt 未満）へ入っても 45% を保持する。
    _ = session.update(pointerX: 550, containerWidth: width)
    let snapClose = session.update(pointerX: 770, containerWidth: width)
    XCTAssertEqual(snapClose, .snapClose(width: 230))
    XCTAssertEqual(snapClose.badgeKind, .snapClose)
    XCTAssertEqual(session.commit(), .close(preservedRatio: 0.45))

    // 右端まで投げ切っても最小閉じプレビュー幅 120pt で床止めする。
    let floorClose = session.update(pointerX: 980, containerWidth: width)
    XCTAssertEqual(floorClose, .snapClose(width: BrowserResizeSession.minClosePreviewWidth))
    XCTAssertEqual(session.commit(), .close(preservedRatio: 0.45))
  }

  /// 狭幅ウィンドウでもシート幅は窓幅を超えず、ドラッグ時は 86% 超の全面吸着を 240pt 未満の閉じ判定より優先する。
  func testNarrowContainerNeverOverflowsAndPrefersFullSnapOverClose() {
    XCTAssertEqual(BrowserResizeSession.sheetWidth(ratio: 0.52, containerWidth: 0), 0)
    XCTAssertEqual(
      BrowserResizeSession.sheetWidth(ratio: 0.30, containerWidth: 500),
      BrowserResizeSession.closeThresholdWidth,
      "240pt 以上を保てる窓では下限幅 240pt を確保する")
    XCTAssertEqual(
      BrowserResizeSession.sheetWidth(ratio: 0.52, containerWidth: 200), 200,
      "240pt 未満の窓では窓幅に収めて破綻させない")

    var session = BrowserResizeSession(initialRatio: 0.52, containerWidth: 200)
    let full = session.update(pointerX: 20, containerWidth: 200)
    XCTAssertEqual(full, .snapFull(width: 200), "rawWidth 180 < 240 でも ratio 0.90 > 0.86 が優先される")

    let close = session.update(pointerX: 60, containerWidth: 200)
    XCTAssertEqual(close, .snapClose(width: 140))
    XCTAssertEqual(session.commit(), .close(preservedRatio: 0.52))
  }
}
