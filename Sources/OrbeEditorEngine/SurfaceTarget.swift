import AppKit
import OrbeEditorCore

/// 行き先を決める 1 段——面の view の入口が最初に通る。点を持つ入口（押す・ドラッグ・右クリック・落とす・字の位置・
/// ポインタの形）は点の下の行き先（`target(at:)`）へ、点を持たない入口（キー・IME・コマンドのセレクタ・メニューの有効判定・
/// undo の入れ物・サービス）は主の場（`primarySite`）へ振り分ける。
enum SurfaceTarget {
  /// 本文の場。
  case body
}

extension MetalTextSurface {
  /// 点（view の座標、pt）の下の行き先。
  func target(at point: CGPoint) -> SurfaceTarget {
    .body
  }

  /// 主の場——キー・IME・コマンドが効く場。
  var primarySite: EditingSite? { bodySite }
}
