import Foundation

/// `.app` 同梱物（`Contents/Resources/`）の探索根。同梱物の所在を解決する唯一の入口で、
/// 同梱リソースのために `Bundle.main` を通す箇所をここ 1 点へ閉じる
/// （`.swiftlint.yml` の custom rule が他所での直参照を落とす）。
/// バンドルを持たない実行体（`swift run`・テスト実行体）では同梱物を持たないディレクトリへ
/// 解決するため、各利用側の存在確認が nil を返す。
/// 存在確認と nil の意味（hook が no-op・PATH 注入なし等）は利用側が持つ。
enum BundledResources {
  /// 同梱物の探索根。
  static var root: URL? = Bundle.main.resourceURL
}
