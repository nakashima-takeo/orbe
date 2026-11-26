import AppKit
import SwiftUI

/// 使い捨ての診断（PR #509 の CI で、検索の列の入力欄にフォーカスが入らない件）。`DIAG509` の印で NSLog へ出す。
enum Diag509 {
  static func log(_ message: String) {
    NSLog(
      "DIAG509 t=%.4f active=%@ %@", CACurrentMediaTime(), "\(NSApp.isActive)", message)
  }
}

/// 組み立てられるたびに記録する印（body の評価の時点を見るため）。
struct Diag509Mark: View {
  init(_ message: String) {
    Diag509.log(message)
  }

  var body: some View { EmptyView() }
}
