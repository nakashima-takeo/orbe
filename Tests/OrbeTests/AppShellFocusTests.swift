import AppKit
import XCTest

@testable import Orbe

/// overlay 遷移時の focus 再確定の観測可能な核＝`AppShellModel.focusCurrentOverlayField()` の検証。
/// 現在の overlay のモデルへ focus（focusToken を進める）を配ることを固定する。去りゆくカードの field editor
/// teardown に奪われた first responder を、次 tick でこの bump が取り戻す（WindowController が async で呼ぶ）。
@MainActor
final class AppShellFocusTests: XCTestCase {

  private func makeModel() -> AppShellModel {
    AppShellModel(statusModel: StatusRowModel(), content: NSView())
  }

  func testFocusesWorkspaceCreateFieldWhenCreateOverlayActive() {
    let model = makeModel()
    let create = WorkspaceCreateModel(path: "~")
    model.workspaceCreate = create
    model.overlay = .workspaceCreate
    let before = create.focusToken
    model.focusCurrentOverlayField()
    XCTAssertEqual(create.focusToken, before &+ 1, "作成フォームの focusToken を進める")
  }

  func testFocusesWorkspacePaletteFieldWhenPaletteOverlayActive() {
    let model = makeModel()
    let palette = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    model.workspacePalette = palette
    model.overlay = .workspacePalette
    // WorkspacePaletteModel.focus() は render.focusToken を進める。
    let before = palette.render.focusToken
    model.focusCurrentOverlayField()
    XCTAssertEqual(palette.render.focusToken, before &+ 1, "切替パレット絞り込み欄の focusToken を進める")
  }

  func testNoOverlayIsNoOp() {
    let model = makeModel()
    model.overlay = .none
    // .none（端末）は host（focusActivePane）が担うため、ここでは何もしない（クラッシュしない）。
    model.focusCurrentOverlayField()
  }

  /// 遷移先が変わったら、その時点の overlay のモデルへ配ることの担保（overlay→overlay の焦点漏れ回避）。
  func testDispatchesToCurrentOverlayAfterSwap() {
    let model = makeModel()
    let create = WorkspaceCreateModel(path: "~")
    let palette = WorkspacePaletteModel(localization: LocalizationStore(language: .ja))
    model.workspaceCreate = create
    model.workspacePalette = palette
    // 作成フォーム → 切替パレットへ切り替わった後は、パレット側だけが進む。
    model.overlay = .workspacePalette
    let createBefore = create.focusToken
    let paletteBefore = palette.render.focusToken
    model.focusCurrentOverlayField()
    XCTAssertEqual(palette.render.focusToken, paletteBefore &+ 1, "遷移先（パレット）へ配る")
    XCTAssertEqual(create.focusToken, createBefore, "去りゆく作成フォームは進めない")
  }
}
