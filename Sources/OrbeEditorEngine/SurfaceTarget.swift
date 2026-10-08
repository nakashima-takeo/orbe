import AppKit
import OrbeEditorCore

/// 面の主——キー・IME・コマンドのセレクタ・メニューの有効判定・undo の入れ物・サービスが効く先。面に 1 つだけある。
enum Primary: Equatable {
  /// 本文の場。
  case body
  /// 区画の選べる文（選択は `MetalTextSurface.zoneSelection`）。⌘C・⌘A・Esc だけが効く。
  case zoneText
  /// 入力欄の場（入力欄の id）。
  case field(AnyHashable)
}

/// 点の下の行き先。区画の上は、入力欄 → 押せる場所 → 選べる文 → 区画の空き の順に当たる。
enum SurfaceTarget {
  case body
  case field(EditingSite)
  case button(ZoneEntry, ZoneHits.Button)
  /// 区画の選べる文のまとまり `text` の位置 `offset`。
  case zoneText(ZoneEntry, text: AnyHashable, offset: Int)
  case zoneSpace(ZoneEntry)
}

/// 行き先を決める 1 段——面の view の入口が最初に通る。点を持つ入口（押す・ドラッグ・右クリック・落とす・字の位置・
/// ポインタの形）は点の下の行き先（`target(at:)`）へ（字の位置は IME への答えなので、点の下が主の場のときだけ答える）、
/// 点を持たない入口（キー・IME・コマンドのセレクタ・メニューの有効判定・undo の入れ物・サービス）は主（`primary`）へ
/// 振り分ける。主の遷移は入口で明示して起こす（`setPrimary`）——カーソルの値の
/// 変化からは推し量らない。
extension MetalTextSurface {
  /// 点（view の座標、pt）の下の行き先。`position` はスクロールの位置（省けば今の位置）。
  func target(at point: CGPoint, position: SIMD2<Double>? = nil) -> SurfaceTarget {
    guard rows.hasZones, textView.overview.area(at: point) == nil else { return .body }
    let area = surfaceLayout.text
    guard point.x >= area.minX, point.x < area.maxX, point.y >= config.topInset else {
      return .body
    }
    let p = position ?? scrollPosition
    let y = Double(point.y - config.topInset) + p.y
    guard case .block(let index) = rows.item(atY: y), case .zone(let id) = rows.contents[index],
      let entry = zones[id]
    else { return .body }
    let local = CGPoint(x: point.x - area.minX, y: CGFloat(y - rows.top(ofBlock: index)))
    if let field = entry.hits.fields.last(where: { $0.frame.contains(local) }),
      let site = fields[field.field.id]
    {
      return .field(site)
    }
    if let button = entry.hits.buttons.last(where: { $0.frame.contains(local) }) {
      return .button(entry, button)
    }
    if let (text, offset) = entry.hits.text(at: local) {
      return .zoneText(entry, text: text, offset: offset)
    }
    return .zoneSpace(entry)
  }

  /// 点（view の座標）の、区画 `zone` の中の座標（区画が並びに無ければ nil）。`position` はスクロールの位置。
  func zonePoint(
    _ point: CGPoint, in zone: ObjectIdentifier, position: SIMD2<Double>? = nil
  ) -> CGPoint? {
    guard let block = rows.block(ofZone: zone) else { return nil }
    let p = position ?? scrollPosition
    return CGPoint(
      x: point.x - surfaceLayout.text.minX,
      y: CGFloat(Double(point.y - config.topInset) + p.y - rows.top(ofBlock: block)))
  }

  /// 主の場——キー・IME・コマンドが効く場（主が区画の文なら nil）。
  var primarySite: EditingSite? {
    switch primary {
    case .body: bodySite
    case .zoneText: nil
    case .field(let id): fields[id]
    }
  }

  /// 主を `next` にする（取引の中）。離れる場の変換を確定し、⌘D の続きを終え、AppKit に入力の文脈を取り直させる。区画の文
  /// から離れれば区画の選択を解く。入力欄には主になった・外れたを知らせる。
  func setPrimary(_ next: Primary) {
    guard next != primary else { return }
    transact {
      let leaving = primarySite
      leaving?.editor.finishComposition(.commit)
      leaving?.editor.focusDidLeave()
      let before = primary
      primary = next
      if next != .zoneText { clearZoneSelection() }
      // AppKit は今の文脈を読まれたとき、first responder の inputContext と食い違えば前の文脈を deactivate・新しい
      // 文脈を activate する。activate・deactivate はシステムが呼ぶ口なので直に呼ばない。
      if textView.window?.firstResponder === textView { _ = NSTextInputContext.current }
      if case .field(let id) = before, let field = fields[id]?.field {
        field.didChangePrimary?(field, false)
      }
      if case .field(let id) = next, let field = fields[id]?.field {
        field.didChangePrimary?(field, true)
      }
    }
  }
}
