import CoreGraphics

/// テストが作る入力の出来事（`CGEvent`）の出どころ。
public enum SyntheticInput {
  /// 自分だけの状態を持つ出どころ。テストが作る出来事を、利用者の実際の入力の状態から切り離す。出どころを nil にすると、
  /// 出来事は利用者の入力の状態を合わせて持ち、利用者が実際にスクロールした直後の短いあいだ、行単位のスクロールの出来事の
  /// 量が 0 になる。
  public static let source = CGEventSource(stateID: .privateState)
}
