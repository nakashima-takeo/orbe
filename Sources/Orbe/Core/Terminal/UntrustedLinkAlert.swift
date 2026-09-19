import AppKit

/// OSC 8 リンクの confirm / block を NSAlert で見せる（終了確認・エディタ未検出と同じ作法・現在言語）。
/// 対象文字列は等幅・選択可の accessory に出す。surface の窓があればシートで、無ければアプリモーダル。
enum UntrustedLinkAlert {
  static func confirm(_ url: URL, display: String, language: Language, in window: NSWindow?) {
    let workspace = NSWorkspace.shared
    let handler = workspace.urlForApplication(toOpen: url)
      .map { $0.deletingPathExtension().lastPathComponent }
    let alert = NSAlert()
    alert.messageText = L10n.string(.linkConfirmTitle, language)
    alert.informativeText =
      handler.map { L10n.format(.linkConfirmMessage, language, $0) }
      ?? L10n.string(.linkConfirmMessageDefaultApp, language)
    alert.accessoryView = targetView(display)
    alert.addButton(withTitle: L10n.string(.commonCancel, language))
    alert.addButton(withTitle: L10n.string(.linkConfirmOpen, language))
    present(alert, in: window) { response in
      guard response == .alertSecondButtonReturn else { return }
      workspace.open(url)
    }
  }

  static func block(
    _ reason: UntrustedLink.BlockReason, display: String, copy: String, language: Language,
    in window: NSWindow?
  ) {
    let alert = NSAlert()
    alert.messageText = L10n.string(.linkBlockedTitle, language)
    alert.informativeText = L10n.string(reason.l10nKey, language)
    alert.accessoryView = targetView(display)
    alert.addButton(withTitle: L10n.string(.linkBlockedOK, language))
    alert.addButton(withTitle: L10n.string(.linkBlockedCopy, language))
    present(alert, in: window) { response in
      // コピーするのは無害化した文字列。開く近道は作らない。
      guard response == .alertSecondButtonReturn else { return }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(copy, forType: .string)
    }
  }

  private static func present(
    _ alert: NSAlert, in window: NSWindow?,
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) {
    if let window {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  private static func targetView(_ target: String) -> NSView {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 72))
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    let textView = NSTextView(frame: scrollView.contentView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.string = target
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
    scrollView.documentView = textView
    return scrollView
  }
}

extension UntrustedLink.BlockReason {
  fileprivate var l10nKey: L10nKey {
    switch self {
    case .malformed: return .linkBlockedMalformed
    case .unsafeCharacters: return .linkBlockedUnsafeCharacters
    case .invalidWeb: return .linkBlockedInvalidWeb
    case .remoteFile: return .linkBlockedRemoteFile
    case .inaccessibleFile: return .linkBlockedInaccessibleFile
    case .unsafeFile: return .linkBlockedUnsafeFile
    }
  }
}
