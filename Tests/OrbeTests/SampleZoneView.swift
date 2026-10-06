import AppKit
import SwiftUI

/// 試しの区画の view——PR のスレッドに近い構成（枠・頭・折り返す文・入力欄）。差し込みの flow（`editor_rows`）と、画面に
/// 出す試しの場（`EditorRowsTrialTests`）が載せる。
///
/// 面は区画に本文の区画の幅を与えて fitting size の高さを測るが、`NSHostingView` は幅の制約だけでは折り返した高さを
/// 返さない。そこで `NSHostingController` を包み、今の幅で SwiftUI に問うた高さを `intrinsicContentSize` として返す
/// （幅が変われば問い直す）。
final class SampleZoneView: NSView {
  private let controller: NSHostingController<SampleZone>

  init(title: String, message: String) {
    controller = NSHostingController(rootView: SampleZone(title: title, message: message))
    controller.sizingOptions = []
    super.init(frame: .zero)
    controller.view.autoresizingMask = [.width, .height]
    addSubview(controller.view)
  }

  required init?(coder: NSCoder) { fatalError("not supported") }

  override var isFlipped: Bool { true }

  override var intrinsicContentSize: NSSize {
    let fitting = controller.sizeThatFits(
      in: NSSize(width: bounds.width, height: .greatestFiniteMagnitude))
    return NSSize(width: NSView.noIntrinsicMetric, height: fitting.height)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize.width != frame.width
    super.setFrameSize(newSize)
    if changed { invalidateIntrinsicContentSize() }
  }
}

/// 試しの区画の中身。枠は区画の上下の境（本文の行との境）が見えるように引く。
struct SampleZone: View {
  let title: String
  let message: String
  @State private var reply = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
      TextField("返信", text: $reply).textFieldStyle(.roundedBorder).font(.system(size: 12))
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6)))
    .padding(.vertical, 4)
    .padding(.leading, 40)
    .padding(.trailing, 16)
  }
}
