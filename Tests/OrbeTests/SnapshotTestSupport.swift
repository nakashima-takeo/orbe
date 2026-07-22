import SwiftUI
import XCTest

@testable import Orbe

/// gallery（静止 fixture）と flow（アクション駆動の連番）が共有する低レベルのスナップショット基盤。
/// オフスクリーン描画（`NSHostingView`＋`cacheDisplay`）・出力先解決・カードを地に置く view ビルダを持つ。
/// アサートはしない（AI/人間が見る）。両テストクラスがこれを継承して使う（重複を作らない）。
@MainActor
class SnapshotTestCase: XCTestCase {

  // MARK: - 描画

  func renderPNG<V: View>(_ view: V, size: NSSize, dark: Bool) -> Data? {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    host.appearance = appearance

    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    // SwiftUI の描画コミットに猶予を与える
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.representation(using: .png, properties: [:])
  }

  /// repo 内 `.preview/<sub>` を返す。このファイル: <repo>/Tests/OrbeTests/...swift → 3 階層上が repo root。
  func previewDir(_ sub: String) -> URL {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return repoRoot.appendingPathComponent(".preview/\(sub)", isDirectory: true)
  }

  // MARK: - カードを地に置く view ビルダ（gallery / flow 共通）

  /// パレットカードを scrim 地に置いたスナップショット用ビュー。
  func paletteSnapshot(_ model: PaletteModel) -> some View {
    PaletteCard(model: model)
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.theme.bgSunken)
  }

  /// 補完 popup を端末地（bg.base＝ターミナル Mocha base）に重ねたスナップショット用ビュー。
  /// scrim を持たない実機と同条件で、e2 影が端末から popup を持ち上げるかを見る。
  func completionSnapshot(_ model: CompletionListModel) -> some View {
    CompletionList(model: model)
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.theme.bgBase)
  }

  /// Onboarding カードを scrim 地に置いたスナップショット用ビュー。
  func onboardingSnapshot(_ model: OnboardingModel) -> some View {
    OnboardingCard(model: model)
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.theme.bgSunken)
  }

  /// 初回言語選択カードを scrim 地に置いたスナップショット用ビュー。言語は明示注入して描画を決定化する
  /// （chrome は `@Environment(\.localization)` で現在言語を読むため）。
  func languageSelectSnapshot(_ language: Language) -> some View {
    LanguageSelectCard(model: LanguageSelectModel(current: language))
      .padding(Theme.Space.phrase)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.theme.bgSunken)
      .environment(\.localization, LocalizationStore(language: language))
  }
}
