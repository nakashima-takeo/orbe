import AppKit

/// 面の機構の上位配線——⌘E・⌘⇧F と、連の配置が変わったときの保存・chrome・焦点の追従。
extension WindowController {
  /// ⌘E。分割中は焦点の往復、それ以外は端末 ⇄ エディター全面。選んでいるタブが無ければ（ボード・空）no-op。
  func toggleEditorFace() {
    guard let group = activeTab?.group else { return }
    group.setFaces(FaceGeometry.toggle(group.view.committed), animated: true)
  }

  /// ⌘⇧F（→ `TabGroup.findInProject`）。選んでいるタブが無ければ no-op。
  func findInProject() {
    activeTab?.group.findInProject()
  }

  /// 連の配置が変わった。保存を予約し chrome を更新し、その連のタブを見ているなら焦点の面へ first responder を戻す
  /// （first responder が既に焦点の面の配下にあれば——面に入った焦点で記憶が追従したときも、サイドバーの入力欄のように
  /// 面の中の別の場所にあるときも——触らない）。
  func groupFacesDidChange(_ group: TabGroup) {
    scheduleSave()
    refreshChrome()
    guard let tab = activeTab, tab.group === group, model.overlay == .none,
      group.view.face(containing: window.firstResponder) != group.faces.focus
    else { return }
    window.makeFirstResponder(tab.focusTarget)
  }
}
