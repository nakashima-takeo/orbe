import AppKit
import OrbeEditorCore

/// 区画 1 つの main の持ち物——載せる側の区画（面が保持する）・絵を問うた幅・最後の絵と、それを写した描く材料と当たりの表。
@MainActor
final class ZoneEntry {
  let zone: SurfaceZone
  var width: CGFloat
  var picture: ZonePicture
  var material = ZoneMaterial()
  var hits = ZoneHits()

  init(zone: SurfaceZone, width: CGFloat, picture: ZonePicture) {
    self.zone = zone
    self.width = width
    self.picture = picture
  }
}

/// ポインタの下の押せる場所。
struct HoveredButton: Equatable {
  var zone: ObjectIdentifier
  var id: AnyHashable
}

/// 区画（絵を問い・材料に写し・幅に合わせ・描き直す）と、入力欄の場（作る・使い回す・閉じる）と、押せる場所のホバー。
/// 絵を問うのも写すのも main の取引の中で、描く材料は並びと同じ書き込みで材料の箱に載る（描画スレッドは引き取った版の
/// 並びと材料で描く）。
extension MetalTextSurface {
  /// 今の本文の区画の幅（区画の絵を問う幅）。
  var zoneWidth: CGFloat { surfaceLayout.text.width }

  /// 置く区画を `list` にする（取引の中）——新しい区画は今の幅で絵を問うて写し、外れた区画は手放す。
  func syncZones(_ list: [SurfaceZone]) {
    let ids = Set(list.map(ObjectIdentifier.init))
    for (id, entry) in zones where !ids.contains(id) {
      zones[id] = nil
      zonesRepainted = true
      orphanFields(of: entry, keeping: [])
      transaction?.writes.append { $0.zones[id] = nil }
      if case .zoneText = primary, zoneSelection?.zone == id { setPrimary(.body) }
      if hoveredButton?.zone == id { hoveredButton = nil }
    }
    let width = zoneWidth
    for zone in list where zones[ObjectIdentifier(zone)] == nil {
      let entry = ZoneEntry(zone: zone, width: width, picture: zone.picture(width: width))
      zones[ObjectIdentifier(zone)] = entry
      paint(entry)
    }
  }

  func redrawZone(_ zone: SurfaceZone) {
    guard let entry = zones[ObjectIdentifier(zone)] else { return }
    transact {
      entry.picture = zone.picture(width: entry.width)
      paint(entry)
    }
  }

  /// 絵を描く材料と当たりの表に写して書く（取引の中）。入力欄の場を作り・使い回し、絵から消えた入力欄の場は取引の終わりに
  /// 閉じる。区画の文の選択を確かめ直す。高さが変われば取引の終わりに並びを組み直す。
  func paint(_ entry: ZoneEntry) {
    let id = ObjectIdentifier(entry.zone)
    let (material, hits) = painter.paint(
      entry.picture,
      ZonePainter.Look(appearance: textView.effectiveAppearance, space: space, scale: scale),
      serial: { fieldSite(for: $0).serial })
    let previous = entry.hits
    entry.material = material
    entry.hits = hits
    zonesRepainted = true
    for field in hits.fields {
      guard let site = fields[field.field.id] else { continue }
      precondition(site.zone == nil || site.zone == id, "入力欄の id は面の中で一意（2 つの区画に置かない）")
      site.zone = id
      site.frame = field.frame
      site.touch()
    }
    orphanFields(of: entry, keeping: Set(hits.fields.map(\.field.id)), previous: previous)
    transaction?.writes.append { $0.zones[id] = material }
    if let block = rows.block(ofZone: id),
      rows.heights[block] != Double(max(0, entry.picture.height))
    {
      zoneHeightsChanged = true
    }
    if zoneSelection?.zone == id { validateZoneSelection(entry) }
  }

  /// 区画 `entry` が描いていた入力欄のうち、`keeping` に無いものを、どの区画も描いていない場にする（取引の終わりに閉じる）。
  private func orphanFields(
    of entry: ZoneEntry, keeping: Set<AnyHashable>, previous: ZoneHits? = nil
  ) {
    let id = ObjectIdentifier(entry.zone)
    for field in (previous ?? entry.hits).fields where !keeping.contains(field.field.id) {
      if let site = fields[field.field.id], site.zone == id { site.zone = nil }
    }
  }

  /// 入力欄 `field` の場（無ければ作る）。同じ id には同じ型の参照が来る。
  func fieldSite(for field: ZoneTextField) -> EditingSite {
    if let site = fields[field.id] {
      precondition(site.field === field, "同じ id の入力欄には、同じ ZoneTextField を渡す")
      return site
    }
    nextFieldSerial += 1
    let site = EditingSite(surface: self, field: field, serial: nextFieldSerial)
    fields[field.id] = site
    return site
  }

  /// 取引の終わりに、区画を今に合わせる（取引の中）——本文の区画の幅が変わっていれば絵を問い直し、どの区画も描いていない
  /// 入力欄の場を閉じ（主なら本文が主になる）、高さが変わった区画で並びを組み直す（閉じた場の知らせの中で描き直した高さも
  /// 同じ取引に入る）。
  /// 区画を写したか外したなら、どの区画の材料も指さない画像の覚えを手放す。
  func settleZones() {
    guard !zones.isEmpty || !fields.isEmpty || zonesRepainted else { return }
    let width = zoneWidth
    for entry in zones.values where entry.width != width {
      entry.width = width
      entry.picture = entry.zone.picture(width: width)
      paint(entry)
    }
    for (id, site) in fields where site.zone == nil {
      if primary == .field(id) { setPrimary(.body) }
      site.editor.finishComposition(.commit)
      fields[id] = nil
      let serial = site.serial
      transaction?.writes.append { $0.fields[serial] = nil }
    }
    if zoneHeightsChanged { applyZoneHeights() }
    if zonesRepainted {
      zonesRepainted = false
      painter.keep(images: Set(zones.values.flatMap { $0.material.images.map(\.pixels.key) }))
    }
  }

  /// 区画の絵の高さで並びを組み直す（見えている先頭の文書の行は確定で保つ）。
  private func applyZoneHeights() {
    zoneHeightsChanged = false
    let current = rows
    var changed = false
    let blocks = current.contents.indices.map { index -> RowLayout.Block in
      let content = current.contents[index]
      var height = current.heights[index]
      if case .zone(let id) = content, let entry = zones[id] {
        let zoneHeight = Double(max(0, entry.picture.height))
        if zoneHeight != height {
          height = zoneHeight
          changed = true
        }
      }
      return RowLayout.Block(line: current.boundaries[index], height: height, content: content)
    }
    guard changed else { return }
    noteRowsChange()
    rows.replace(blocks)
  }

  /// 取引の中で並びが変わる（取引の前の並びを、見えている先頭の文書の行を保つ起点として覚える）。
  func noteRowsChange() {
    if transaction?.anchor == nil { transaction?.anchor = rows }
  }

  /// 外観・色空間・倍率が変わった——区画の色と画像を写し直し（絵は問い直さない）、入力欄の色を解き直す。
  func zonesAppearanceDidChange() {
    guard !zones.isEmpty || !fields.isEmpty else { return }
    transact {
      for entry in zones.values { paint(entry) }
      for site in fields.values {
        site.palette = nil
        site.touch()
      }
    }
  }

  // MARK: - 入力欄（契約）

  func replaceText(of field: ZoneTextField, with text: String) {
    let site = fieldSite(for: field)
    site.editor.replaceAll(with: text)
  }

  func focus(_ field: ZoneTextField) {
    _ = fieldSite(for: field)
    setPrimary(.field(field.id))
  }

  // MARK: - 押せる場所のホバー

  /// ポインタ（view の座標。view の外なら nil）の下の押せる場所へホバーを移し、出入りを載せる側へ知らせる。
  func hover(at point: CGPoint?) {
    guard !hovering else { return }
    var next: HoveredButton?
    if let point, case .button(let entry, let button) = target(at: point) {
      next = HoveredButton(zone: ObjectIdentifier(entry.zone), id: button.id)
    }
    guard next != hoveredButton else { return }
    hovering = true
    defer { hovering = false }
    let previous = hoveredButton
    hoveredButton = next
    inputScope {
      if let previous { zones[previous.zone]?.zone.zone(.exited(previous.id)) }
      if let next { zones[next.zone]?.zone.zone(.entered(next.id)) }
    }
  }

  /// 窓の今のポインタの位置でホバーとポインタの形を引き直す（スクロール・並び・区画の絵が変わり、押せる場所がポインタの
  /// 下を動いた）。
  func refreshPointer() {
    guard rows.hasZones || hoveredButton != nil, let window = textView.window else { return }
    let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let inside = textView.bounds.contains(point) && window.isKeyWindow
    hover(at: inside ? point : nil)
    if inside {
      textView.pointer.updatePointer(
        at: window.mouseLocationOutsideOfEventStream, flags: NSEvent.modifierFlags, in: textView)
    }
  }
}
