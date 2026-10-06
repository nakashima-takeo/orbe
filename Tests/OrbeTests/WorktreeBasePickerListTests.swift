import AppKit
import SwiftUI
import XCTest

@testable import Orbe

/// ベースを選ぶ画面のリストがカードへ伝える実測高。候補は全ローカル・リモートブランチで千を超えうる。
/// 壊れると何が起きるか: 上限で切らずに流すと、Lazy の推定高がスクロールのたびに動いてカード全体が描き
/// 直され、ブランチの多いリポジトリでベースを選ぶ画面のスクロールと ↑↓ がもたつく。
@MainActor
final class WorktreeBasePickerListTests: OrbeTestCase {
  private var windows: [NSWindow] = []

  override func tearDown() {
    windows.forEach { $0.orderOut(nil) }
    windows.removeAll()
    super.tearDown()
  }

  /// 候補が上限を超える高さになっても、伝える実測高は一覧と同じ上限で止まる。
  func testReportedHeightStopsAtTheListCap() {
    let candidates = (0..<300).map {
      WorktreeBaseCandidate(name: "origin/feat/\($0)", relativeDate: "1d", isRemote: true)
    }
    let box = HeightBox()
    let list = WorktreeBasePickerList(
      model: WorktreeBasePickerModel(candidates: candidates), onConfirm: { _ in }
    )
    .onPreferenceChange(WorktreePaletteContentHeightKey.self) { box.value = $0 }

    render(list)

    XCTAssertEqual(box.value, WorktreePaletteCard.listCap)
  }

  private func render(_ view: some View) {
    let host = NSHostingView(rootView: view.frame(width: 720, height: 600))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    windows.append(window)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    host.layoutSubtreeIfNeeded()
  }

  /// preference の遡上値をビューの外へ持ち出す箱。
  private final class HeightBox {
    var value: CGFloat = -1
  }
}
