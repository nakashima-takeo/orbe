import CoreGraphics

/// テストが作る入力の出来事（`CGEvent`）の出どころ。
public enum SyntheticInput {
  /// 自分だけの状態を持つ出どころ。テストが作る出来事を、利用者の実際の入力の状態から切り離す（位置は切り離さない。
  /// ホイールの出来事の位置は、設定しなければ利用者の実際のポインタの位置になる）。出どころを nil にすると、
  /// 既定の出どころが使われる。そのとき、利用者が実際にスクロールした直後の短いあいだ、行単位のスクロールの出来事の量が
  /// 0 になったことがある（再現しない環境もある）。
  public static let source = CGEventSource(stateID: .privateState)
}
