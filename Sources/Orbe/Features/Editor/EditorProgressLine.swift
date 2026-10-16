import AppKit
import SwiftUI

/// 進みの細い線（見本に無い。VS Code のビューの上端の線。検索パネルの検索中・ソース管理の実行中の帯）——accent の短い帯が
/// 左から右へ流れ続ける。帯の動きは Core Animation に任せる——SwiftUI の時刻で毎フレーム描くと、走っている間ずっと main が
/// 毎フレームパネルを組み直し、結果の差し込みや打鍵を待たせる。
struct EditorProgressLine: NSViewRepresentable {
  func makeNSView(context: Context) -> EditorProgressLineView { EditorProgressLineView() }
  func updateNSView(_ view: EditorProgressLineView, context: Context) {}

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: EditorProgressLineView, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 0, height: Theme.Layout.editorProgressLine)
  }
}

final class EditorProgressLineView: NSView {
  private static let period: CFTimeInterval = 1.2
  private static let segment: CGFloat = 0.3
  private let bar = CALayer()
  private var animatedWidth: CGFloat?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(bar)
  }
  required init?(coder: NSCoder) { fatalError("not supported") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      bar.backgroundColor = Theme.Color.accentPrimary.cgColor
    }
  }

  override func layout() {
    super.layout()
    guard bounds.width != animatedWidth else { return }
    animatedWidth = bounds.width
    let width = bounds.width * Self.segment
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bar.frame = CGRect(x: -width, y: 0, width: width, height: bounds.height)
    CATransaction.commit()
    let flow = CABasicAnimation(keyPath: "position.x")
    flow.fromValue = -width / 2
    flow.toValue = bounds.width + width / 2
    flow.duration = Self.period
    flow.repeatCount = .infinity
    bar.add(flow, forKey: "flow")
  }
}
