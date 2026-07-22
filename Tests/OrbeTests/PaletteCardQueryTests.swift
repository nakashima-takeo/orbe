import SwiftUI
import XCTest

@testable import Orbe

/// `PaletteCard`（view）とパレットモデルの結線の検証。モデルを直叩きするテストは `onQueryChange()` を
/// 明示的に呼ぶため、「view が `model.query` の**値変化**に反応して跳ね返る」経路を原理的に踏めない。
/// その 1 点だけをここで実描画（`SnapshotTestCase` の `NSHostingView` 基盤）で固定する。
@MainActor
final class PaletteCardQueryTests: SnapshotTestCase {
  private var windows: [NSWindow] = []

  override func tearDown() {
    windows.removeAll()
    super.tearDown()
  }

  /// view を実際にマウントし、SwiftUI の更新を回せる状態にする。
  private func mount<V: View>(_ view: V) -> NSHostingView<V> {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 320)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    windows.append(window)  // view ツリーを生かしておく
    pump(host)
    return host
  }

  /// SwiftUI の描画コミット（Binding・onChange の反映）を 1 巡させる。
  private func pump(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  }

  /// 絞り込み中の root からサブパレットへ潜ると `setMode` が `query` を空へ戻す。この **モデル自身の**
  /// 書き込みが view から `onQueryChange` へ跳ね返ると、モデルが置いた選択（現在値の行）が 0 に潰れ、
  /// 「ハイライト＝● ＝↵ の着地点」が主要導線（打鍵で絞り込む → 潜る）で破れる。
  /// さらにその状態の ↵ は `fontFamily(nil)` を書き、設定済みフォントを消してしまう。
  func testProgrammaticQueryClearDoesNotResetSubpaletteSelection() {
    var global = SettingsLayer()
    global[SettingKeys.fontSize] = 12
    global[SettingKeys.backgroundOpacity] = 90
    global[SettingKeys.backgroundBlur] = false
    global[SettingKeys.cursorStyleBlink] = false
    global[SettingKeys.fontFamily] = "Menlo"
    let p = SettingsPaletteModel(
      values: ScopedSettingsValues(global: global),
      fontNames: ["Menlo", "Monaco"], agents: [],
      localization: LocalizationStore(language: .ja))
    let host = mount(PaletteCard(model: p.render))

    p.render.query = "フォント"  // root で絞り込む（ユーザーの打鍵と同じ）
    p.render.onQueryChange()
    pump(host)
    XCTAssertEqual(
      p.render.rows.map(\.label),
      [
        "フォントサイズ  12pt", "フォント  Menlo", "タブタイトルのフォント  既定（システム等幅）",
        "絵文字フォント  Noto（同梱）",
      ],
      "root が 4 行へ絞られる")

    p.render.onDown()  // 「フォント」行へ
    p.render.onActivate()  // ↵ で font サブへ潜る（setMode が query を "" へ戻す）
    XCTAssertEqual(p.render.selected, 1, "現在値 Menlo の行に乗る（同期直後）")

    pump(host)  // view の更新を回す＝query クリアが跳ね返るならここで選択が潰れる
    XCTAssertEqual(p.render.selected, 1, "描画更新後も現在値の行のまま（モデルの query クリアは跳ね返らない）")
    XCTAssertEqual(p.render.rows[p.render.selected].label, "● Menlo", "ハイライト＝● ＝↵ の着地点")
  }
}
