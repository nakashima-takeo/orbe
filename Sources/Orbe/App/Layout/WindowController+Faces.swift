import AppKit

/// 面の機構の上位配線——⌘E と、配置が変わったときの保存・chrome・焦点の追従。
extension WindowController {
  /// ⌘E。分割中は焦点の往復、それ以外は端末 ⇄ エディター全面。0 タブは no-op。
  func toggleEditorFace() {
    guard let tab = activeTab else { return }
    tab.setFaces(FaceGeometry.toggle(tab.view.resolved), animated: true)
  }

  /// タブの配置が変わった。保存を予約し chrome を更新し、そのタブを見ているなら焦点の面へ first
  /// responder を戻す（面自身が first responder になった通知で来たときは既に合っているので触らない）。
  func tabFacesDidChange(_ tab: TerminalTab) {
    scheduleSave()
    refreshChrome()
    guard tab === activeTab, model.overlay == .none, window.firstResponder !== tab.focusTarget
    else { return }
    window.makeFirstResponder(tab.focusTarget)
  }
}
