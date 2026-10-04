import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// 上段（TopBar）が信号機の在り処に応じてどこから描き始めるかを、実際に描いた画で固定する。
/// 観察点は上段の帯に落ちた墨——一番左の列（＝現在地テキストの始まり）と、縦の重心。
///
/// 壊れると何が起きるか。信号機が chrome の上に無い（ネイティブ・フルスクリーン）あいだに柱を
/// 畳まないと、上段左に 80pt の空白の穴が残り、workspace 名が画面端から遠く浮いたまま読まれる。
/// 逆に信号機がある窓状態で柱を畳むと、テキストが信号機の下へ潜り込んで両方が読めなくなる。
/// 既定値が柱の空いた姿でないと、probe を持たない見本系（preview・gallery）と probe が読む前の
/// 初回描画が柱の無い姿で出て、実行時に一拍おいて 16→80pt へ跳ねる。
/// 数値は宣言を読めば分かるが、どのトークンが上段のどこに効くかは描いて測らないと分からない。
@MainActor
final class ChromeTopBarMetricsTests: OrbeTestCase {
  private var windows: [NSWindow] = []
  private let canvasWidth: CGFloat = 600

  override func tearDown() {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    super.tearDown()
  }

  /// 上段の帯に落ちた墨の広がり（pt・上段左上が原点）。
  private struct Ink {
    let leading: CGFloat
    let centerY: CGFloat
  }

  /// 現在地テキストだけを載せた chrome を暗地に描き、上段の帯の墨を測る。
  /// `configure` を渡さなければ `StatusRowModel` の既定＝probe を持たない見本系と同じ条件。
  private func topBarInk(_ configure: (StatusRowModel) -> Void = { _ in }) throws -> Ink {
    let model = StatusRowModel()
    model.update(
      StatusRowModel.Snapshot(
        workspace: "WWWW", strip: TabStrip(), active: 0, location: nil, faceDots: nil, rollup: []))
    configure(model)

    let appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(
      rootView: ZStack {
        Color.black
        StatusRowView(model: model)
      }
      .frame(width: canvasWidth, height: Chrome.barHeight))
    host.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: Chrome.barHeight)
    host.appearance = appearance
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    windows.append(window)
    host.layoutSubtreeIfNeeded()
    // SwiftUI の描画コミットに猶予を与える（固定 sleep 無しでは白紙を測りうる）。
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))

    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    return try ink(rep)
  }

  /// 手元 2x・CI 1x の差を吸うため、画素をキャンバス幅で割った倍率で pt へ戻す。
  private func ink(_ rep: NSBitmapImageRep) throws -> Ink {
    let scale = CGFloat(rep.pixelsWide) / canvasWidth
    let band = Int(Chrome.headerHeight * scale)
    var leading: Int?
    var weighted = 0.0
    var count = 0.0
    for x in 0..<rep.pixelsWide {
      for y in 0..<band {
        guard let color = rep.colorAt(x: x, y: y), color.brightnessComponent > 0.25 else {
          continue
        }
        if leading == nil { leading = x }
        weighted += Double(y)
        count += 1
      }
    }
    let first = try XCTUnwrap(leading, "上段に墨が無い（描画が空）")
    return Ink(
      leading: CGFloat(first) / scale, centerY: CGFloat(weighted / count) / scale)
  }

  /// 見本系（probe を持たない）と probe が読む前の初回描画は、信号機が上段の縦中央にある
  /// （寄せ量 0）姿で描かれ、左の柱が空く。
  func testTopBarLeavesTheTrafficLightColumnByDefault() throws {
    let ink = try topBarInk()

    XCTAssertEqual(ink.leading, Chrome.leftColumn, accuracy: 2, "信号機を避ける左の柱")
  }

  /// 信号機が chrome の上に無いあいだ、柱は通常の左右余白へ畳まれ、縦も信号機へ寄らない。
  func testTopBarCollapsesTheTrafficLightColumnWhenTrafficLightsAreAbsent() throws {
    let absent = try topBarInk { $0.trafficLights = .absent }
    // 信号機が上段の縦中央にある＝寄せ量 0 の姿（既定）と、そこから下へ寄る姿。
    let centered = try topBarInk()
    let lowered = try topBarInk { $0.trafficLights = .over(centerY: Chrome.headerHeight / 2 + 8) }

    XCTAssertEqual(absent.leading, Chrome.edgePad, accuracy: 2, "TopBar の通常の左余白")
    XCTAssertEqual(absent.centerY, centered.centerY, accuracy: 0.5, "信号機へ寄せる縦シフトも消える")
    XCTAssertGreaterThan(
      lowered.centerY, centered.centerY + 2, "信号機が下にあれば寄る＝この計測が寄せ量に反応する")
  }
}
