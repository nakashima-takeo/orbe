import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// タブ行の殻（`tabRowShell`）と chrome 2 段の寸法契約を、実際に描いた寸法で固定する。
///
/// 壊れると何が起きるか。殻は実行の行と `#Preview` / gallery が共有する唯一の器で、行の左右端の
/// 隙間はセグメント間の隙間と同じトークンから出る（§5.1）。左右と上下の余白が入れ替わる・
/// 導出が literal に戻ると、`tabGap` を動かしても端が追随せず、端だけリズムの崩れた行になる。
/// 行高の固定が外れると行が中身の高さで伸び、chrome 2 段の全高が `Chrome.barHeight` を超えて
/// ターミナル本文と重なる。トークンの値は宣言を読めば分かるが、**どの辺にどのトークンが効いて
/// 全体が何になるか**は描いて測らないと分からない。
@MainActor
final class ChromeTabRowMetricsTests: OrbeTestCase {

  /// 殻に入れる中身の幅。値そのものに意味はなく、殻が足す量だけを見る。
  private let contentWidth: CGFloat = 100

  private func fittingSize<V: View>(_ view: V) -> NSSize {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private func shell(contentHeight: CGFloat) -> NSSize {
    fittingSize(Color.clear.frame(width: contentWidth, height: contentHeight).tabRowShell())
  }

  // MARK: - 行の殻

  /// 行の左右端に空く隙間は、セグメントとセグメントの隙間と同じ幅（端でリズムが崩れない）。
  func testTabRowShellPadsBothSidesByTheSegmentGap() {
    let size = shell(contentHeight: Chrome.tabHeight)

    XCTAssertEqual(
      size.width, contentWidth + Chrome.tabGap * 2, accuracy: 0.5, "左右端の隙間＝セグメント間の隙間")
  }

  /// 行高は中身に依らず固定。中身が伸びても行は伸びない（伸びれば chrome 全高が狂う）。
  func testTabRowShellHoldsRowHeightRegardlessOfContent() {
    XCTAssertEqual(shell(contentHeight: Chrome.tabHeight).height, Chrome.tabRowHeight, "セグメント高の中身")
    XCTAssertEqual(
      shell(contentHeight: Chrome.tabRowHeight * 4).height, Chrome.tabRowHeight, "行高を超える中身でも行高のまま")
  }

  // MARK: - chrome 2 段

  /// chrome は上段（TopBar）とタブ行の 2 段ちょうどに組み上がる。`WindowController` は
  /// `Chrome.barHeight` を chrome に予約してその下からターミナル本文を始めるので、ここが増えると
  /// 本文に食い込む。
  func testChromeRowLaysOutToBarHeight() {
    let model = StatusRowModel()
    model.update(
      StatusRowModel.Snapshot(
        workspace: "ws",
        strip: TabStrip(titles: ["a", "b"], tabIds: [0, 1], segments: [0..<2], colorIndices: [0]),
        active: 0, location: nil, faceDots: nil, rollup: []))

    let size = fittingSize(StatusRowView(model: model).frame(width: 800))

    XCTAssertEqual(size.height, Chrome.barHeight, "上段＋タブ行＝chrome 全高")
  }
}
