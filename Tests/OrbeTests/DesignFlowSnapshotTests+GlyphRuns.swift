import AppKit
import CoreText
import XCTest

@testable import Orbe

/// パレット行のフォント run 割り当て（[chrome](docs/spec/chrome/chrome.md)）を絵で確かめる flow。
///
/// 端末系グリフ（Nerd の私用領域・点字）は CoreText のフォールバック探索から外れるため、
/// `ChromeFontResolver` を通した run 割り当てだけが描ける。通し忘れた行は同じ文字列を別の字形
/// ——私用領域なら「?」の箱——で描き、他の行と食い違う。行の種類ごとに配線が分かれている以上、
/// 割り当ての有無は行単位で崩れうるので、同じ文字列を複数の行種へ同時に流して字形の一致を見る。
///
/// 同梱 TTF は `.process` 登録された `.app` でしか名前解決できず、`swift test` の素のプロセスでは
/// 割り当て先が nil に落ちて割り当ての有無が絵に出ない。ここでリポジトリ内の JuliaMono を
/// 登録するのはそのためで、撮り終えたら外してプロセスの状態を戻す。
extension DesignFlowSnapshotTests {
  func testWorkspaceGlyphRuns() throws {
    let font = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // OrbeTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // リポジトリ根
      .appendingPathComponent("app/JuliaMono-Regular.ttf")
    guard CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil) else {
      return XCTFail("点字グリフの割り当て先（JuliaMono）を登録できない: \(font.path)")
    }
    defer { CTFontManagerUnregisterFontsForURL(font as CFURL, .process, nil) }

    let size = NSSize(width: 500, height: 320)
    let workspace = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    let items = [
      WorkspacePaletteModel.Item(
        index: 0, name: "⣷⣯⣷ spinner", isActive: true, dir: "/",
        live: .init(rollup: [], dormant: false))
    ]
    try flow(
      "workspace_glyph_runs", size: size,
      render: { paletteSnapshot(workspace.render, canvas: size) },
      steps: [
        ("workspace_row", { workspace.setItems(items) }),
        (
          "with_create_row",
          {
            // 名前の部分一致＝workspace 行が残り、完全同名ではないので作成導線行も同じ点字を持つ。
            // 2 行が同じ字形で並べば、どちらも割り当てを通っている。
            workspace.render.query = "⣷⣯⣷ spin"
            workspace.render.onQueryChange()
          }
        ),
      ])
  }
}
