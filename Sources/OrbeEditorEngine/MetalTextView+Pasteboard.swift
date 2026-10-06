import AppKit
import OrbeEditorCore

/// コピー・カット・ペースト（VS Code の既定）、サービス、右クリックのメニュー。どれも主の場で動き、IME 以外の入口なので、
/// 先に変換を確定してから動く。
extension MetalTextView {
  /// 行ごと写した印（Orbe の型。中身は空）。
  static let entireLineType = NSPasteboard.PasteboardType("dev.orbe.editor.line")
  /// 写した断片（Orbe の型。選択を 2 つ以上写したときの、文書の順の文字列の列）。他のアプリが書けば型ごと消えるので、
  /// 古い断片を取り違えない。
  static let piecesType = NSPasteboard.PasteboardType("dev.orbe.editor.pieces")

  // MARK: - コピー・カット・ペースト

  /// 選択を写す。選択が空ならキャレットの行を写し、行ごと写した印を付ける。選択を 2 つ以上写せば断片も載せる。色の付く
  /// 文書で、写したものが本文の 1 つの範囲（選択 1 つか、選択が空のときの 1 行）で 64KB 未満なら、構文色付きの HTML も
  /// 載せる。主が区画の文なら、選んだまとまりの文の部分を平文で写す（折り返しで改行は入らない。選択が空なら何もしない）。
  @objc func copy(_ sender: Any?) {
    guard surface?.primary != .zoneText else {
      guard let text = surface?.zoneSelectedText else { return }
      pasteboard.declareTypes([.string], owner: nil)
      pasteboard.setString(text, forType: .string)
      return
    }
    surface?.inputScope { writeCopy() }
  }

  /// 写してから消す。選択が空なら行を消す。
  @objc func cut(_ sender: Any?) {
    surface?.input {
      writeCopy()
      surface?.primarySite?.editor.perform(.cut)
    }
  }

  /// 平文を貼る（Finder でコピーしたファイルならパス）。改行は文書の作法へ揃え、行ごと写した文字列は条件が揃えば行の上へ
  /// 入れ、写した断片か行の数がカーソルの数と同じなら 1 つずつ配る。RTF と HTML は読まない。
  @objc func paste(_ sender: Any?) {
    guard let surface, let editor = surface.primarySite?.editor else { return }
    surface.input {
      editor.finishComposition(.commit)
      if let host = surface.host, let urls = fileURLs(on: pasteboard) {
        editor.perform(.paste(host.insertionText(forFiles: urls), entireLine: false))
        return
      }
      guard let string = pasteboard.string(forType: .string) else { return }
      editor.perform(
        .paste(
          string, entireLine: pasteboard.availableType(from: [Self.entireLineType]) != nil,
          pieces: pasteboard.propertyList(forType: Self.piecesType) as? [String]))
    }
  }

  /// ペーストと同じ（書式を持たないので揃える書式が無い）。
  @objc func pasteAsPlainText(_ sender: Any?) {
    paste(sender)
  }

  /// 貼れるもの（平文かファイル）があるか。
  var canPaste: Bool {
    pasteboard.availableType(from: [.string]) != nil || fileURLs(on: pasteboard) != nil
  }

  private func writeCopy() {
    guard let surface, let site = surface.primarySite else { return }
    site.editor.finishComposition(.commit)
    guard let content = site.currentContent else { return }
    let copied = ClipboardText.copy(
      site.editor.state.cursors, content.text, lineBreak: site.lineBreak)
    let html = copied.range.flatMap { range in
      site.isBody
        ? HTMLCopy.html(content.text, range, roles: content.roles, style: surface.htmlStyle()) : nil
    }
    var types: [NSPasteboard.PasteboardType] = [.string]
    if copied.entireLine { types.append(Self.entireLineType) }
    if copied.pieces != nil { types.append(Self.piecesType) }
    if html != nil { types.append(.html) }
    pasteboard.declareTypes(types, owner: nil)
    pasteboard.setString(copied.text, forType: .string)
    if copied.entireLine { pasteboard.setData(Data(), forType: Self.entireLineType) }
    if let pieces = copied.pieces { pasteboard.setPropertyList(pieces, forType: Self.piecesType) }
    // 文字コードの指定が無いと、Cocoa のリッチテキストの貼り先は HTML を UTF-8 でなく読んで化ける（Chromium と同じく、
    // 書く側で前に置く）。
    if let html { pasteboard.setString("<meta charset='utf-8'>" + html, forType: .html) }
  }

  /// ペーストボードのファイルの URL（無ければ nil）。
  func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
    let urls =
      pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
    return urls.isEmpty ? nil : urls
  }

  // MARK: - サービス

  /// 平文を送る（選択があるとき）と受ける（主が編集の場のとき）。主が区画の文の間は送るだけ。
  override func validRequestor(
    forSendType sendType: NSPasteboard.PasteboardType?,
    returnType: NSPasteboard.PasteboardType?
  ) -> Any? {
    let zoneText = surface?.primary == .zoneText
    let selected =
      zoneText
      ? surface?.zoneSelectedText != nil
      : (surface?.primarySite?.editor.state.cursors.primary.selection.length ?? 0) > 0
    let sends = sendType == nil || (sendType == .string && selected)
    let returns = returnType == nil || (returnType == .string && !zoneText)
    guard sends, returns, sendType != nil || returnType != nil else {
      return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    return self
  }

  // MARK: - 右クリック

  /// 右クリック・⌃クリックのメニュー（中身と文言は載せる側が組む）。先に変換を確定し、焦点を取り、点の下の行き先を主に
  /// する。本文と入力欄は、選択の外で押せばキャレットをそこへ動かし、選択の中（両端を含む）なら選択を保つ。区画の選べる
  /// 文は、選択の外で押せば押した点を選び、メニューはコピーだけにする。区画の空きは本文を主にするだけで、押せる場所には
  /// メニューを出さない。
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    guard let surface, let host = surface.host, overview.area(at: point) == nil else { return nil }
    let target = surface.target(at: point)
    if case .button = target { return nil }
    surface.input {
      surface.primarySite?.editor.finishComposition(.commit)
      window?.makeFirstResponder(self)
      switch target {
      case .body:
        surface.setPrimary(.body)
        placeCaret(at: point, in: surface.bodySite)
      case .field(let site):
        if let field = site.field { surface.setPrimary(.field(field.id)) }
        placeCaret(at: point, in: site)
      case .zoneText(let entry, let text, let offset):
        let selection = surface.zoneSelection
        let inside =
          selection?.zone == ObjectIdentifier(entry.zone) && selection?.text == text
          && selection.map { NSLocationInRange(offset, $0.range) || offset == NSMaxRange($0.range) }
            == true
        if !inside {
          surface.beginZoneSelection(entry, text: text, offset: offset, clicks: 1, extending: false)
        }
        surface.setPrimary(.zoneText)
      case .zoneSpace:
        surface.setPrimary(.body)
      case .button:
        break
      }
    }
    let menu = host.contextMenu()
    if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
    if surface.primary == .zoneText {
      for item in menu.items.reversed() where item.action != #selector(copy(_:)) {
        menu.removeItem(item)
      }
    }
    return menu
  }

  /// 右クリックの点が場の選択の外なら、キャレットをそこへ動かす。
  private func placeCaret(at point: CGPoint, in site: EditingSite) {
    guard let hit = site.hit(point), hit.area == .text else { return }
    let selection = site.editor.state.cursors.primary.selection
    let inside =
      selection.length > 0 && hit.offset >= selection.location
      && hit.offset <= NSMaxRange(selection)
    if !inside { site.editor.select(CursorList(Cursor(hit.offset)), reveal: .none) }
  }

  /// AppKit が開く直前に足す項目のうち、AutoFill を取り除く（Writing Tools はメニューに足させない。サービスは残す）。
  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    for item in menu.items.reversed() where Self.isAutoFill(item) {
      menu.removeItem(item)
    }
  }

  /// AutoFill の項目か（公開の識別子が無いので、AppKit が付ける識別子と操作の名前で見分ける）。
  private static func isAutoFill(_ item: NSMenuItem) -> Bool {
    let names = [item.identifier?.rawValue, item.action.map(NSStringFromSelector)].compactMap { $0 }
    return names.contains { $0.localizedCaseInsensitiveContains("autofill") }
  }
}

extension MetalTextView: @preconcurrency NSServicesMenuRequestor {
  /// サービスへ選択の平文を渡す（主が区画の文なら、選んだ区画の文）。
  func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    if surface?.primary == .zoneText {
      guard types.contains(.string), let text = surface?.zoneSelectedText else { return false }
      pboard.declareTypes([.string], owner: nil)
      return pboard.setString(text, forType: .string)
    }
    guard let surface, let site = surface.primarySite, types.contains(.string),
      let text = site.currentContent?.text
    else { return false }
    surface.inputScope { site.editor.finishComposition(.commit) }
    let selection = site.editor.state.cursors.primary.selection
    guard selection.length > 0 else { return false }
    pboard.declareTypes([.string], owner: nil)
    return pboard.setString(text.substring(selection), forType: .string)
  }

  /// サービスが返した平文で主の場の選択を置き換える（前後で区切る。主が区画の文なら受けない）。
  func readSelection(from pboard: NSPasteboard) -> Bool {
    guard let surface, let site = surface.primarySite, let string = pboard.string(forType: .string)
    else { return false }
    surface.inputScope { site.editor.perform(.paste(string, entireLine: false)) }
    return true
  }
}
