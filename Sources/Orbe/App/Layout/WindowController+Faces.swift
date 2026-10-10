import AppKit

/// 面の機構の上位配線——⌘E・⌘⇧F と、配置が変わったときの保存・chrome・焦点の追従。
extension WindowController {
  /// ⌘E。分割中は焦点の往復、それ以外は端末 ⇄ エディター全面。選んでいるタブが無ければ（ボード・空）no-op。
  func toggleEditorFace() {
    guard let tab = activeTab else { return }
    tab.setFaces(FaceGeometry.toggle(tab.view.committed), animated: true)
  }

  /// ⌘⇧F（→ `TerminalTab.findInProject`）。選んでいるタブが無ければ no-op。
  func findInProject() {
    activeTab?.findInProject()
  }

  /// タブの配置が変わった。保存を予約し chrome を更新し、そのタブを見ているなら焦点の面へ first
  /// responder を戻す（first responder が既に焦点の面の配下にあれば——面に入った焦点で記憶が追従したときも、
  /// サイドバーの入力欄のように面の中の別の場所にあるときも——触らない）。
  func tabFacesDidChange(_ tab: TerminalTab) {
    scheduleSave()
    refreshChrome()
    guard tab === activeTab, model.overlay == .none,
      tab.view.face(containing: window.firstResponder) != tab.faces.focus
    else { return }
    window.makeFirstResponder(tab.focusTarget)
  }
}
