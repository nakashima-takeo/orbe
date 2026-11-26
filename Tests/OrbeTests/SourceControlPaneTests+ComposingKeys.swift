import AppKit
import ObjectiveC
import OrbeTestSupport
import XCTest

@testable import Orbe

/// 変換中のメッセージ欄の ↵・⌘↵——変換中の ↵ は IME が変換の確定に使い、コミットしない。確定の後の ↵ でコミットする。
/// ⌘↵ は変換中でも、変換を確定してからコミットしてプッシュする。
///
/// 壊れると何が起きるか。日本語入力で変換の確定のつもりで押した ↵ が、打ちかけのメッセージでコミットする。変換中の ⌘↵ が、
/// 未確定の字の抜けたコミットを push するか、何も起こさない。
extension SourceControlPaneTests {
  /// 変換中の ↵ は変換の確定だけで、コミットは始まらず、確定した字はメッセージに入る。確定の後の ↵ でコミットする。
  func testReturnWhileComposingOnlyConfirmsAndTheNextReturnCommits() throws {
    let repo = try TempGitRepo()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    pumpMain(until: { scm.changes.changes.count == 1 }, "変更の行")
    let field = try type("abc", in: hosted)
    ConfirmingInputMethod.use(for: field, in: self)
    compose("かん", in: field)
    let head = repo.head()

    field.keyDown(with: .key("\r", []))
    XCTAssertTrue(scm.control.operations.isEmpty, "変換中の ↵ ではコミットが始まらない")
    XCTAssertFalse(field.hasMarkedText(), "前提: IME が変換を確定した")
    pumpMain(until: { scm.control.message == "abcかん" }, "確定した字がメッセージに入る")
    XCTAssertEqual(repo.head(), head)

    field.keyDown(with: .key("\r", []))
    pumpMain(
      until: { scm.control.operations.isEmpty && scm.control.message.isEmpty }, timeout: 20,
      "確定の後の ↵ でコミット")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "abcかん\n")
  }

  /// 変換中の ⌘↵ は、変換を確定してから、見えていた字のメッセージでコミットしてプッシュする。
  func testCommandReturnWhileComposingConfirmsThenCommitsAndPushes() throws {
    let repo = try TempGitRepo()
    repo.addOrigin()
    try repo.write("a.txt", "edited\n")
    let hosted = host(repo)
    let scm = hosted.scm
    let field = try type("abc", in: hosted)
    compose("かん", in: field)
    pumpMain(
      until: { self.messageFieldHasFocus(hosted) && scm.commitState.canCommitAndPush },
      "前提: 欄にフォーカスがあり、コミットしてプッシュできる")

    XCTAssertTrue(hosted.pane.performKeyEquivalent(with: .key("\r")))
    pumpMain(until: { scm.control.operations.isEmpty }, timeout: 20, "コミットしてプッシュ")
    XCTAssertEqual(repo.git(["log", "-1", "--format=%s"]).stdoutText, "abcかん\n")
    XCTAssertEqual(
      repo.git(["rev-parse", "origin/main"]).stdoutText, repo.head() + "\n", "push する")
  }
}

/// 偽の IME。変換中に届いたキーは変換の確定に使い（変換中の字をそのまま入れる）、変換中でなければ改行の命令として流す。
/// メッセージ欄（`MessageTextView`）の入力の仕組みを、欄ごとに差し替える——欄は入力の仕組みを外から受け取らないので、
/// `inputContext` を欄の型に足し、偽物を渡した欄にだけ偽物を返す（ほかの欄は NSTextView のまま）。
@MainActor
private final class ConfirmingInputMethod: NSTextInputContext {
  nonisolated(unsafe) private static var contexts: [ObjectIdentifier: NSTextInputContext] = [:]
  private static var installed = false

  /// `field` の入力の仕組みを、テスト `test` の終わりまで偽の IME にする。
  static func use(for field: MessageTextView, in test: XCTestCase) {
    install()
    let id = ObjectIdentifier(field)
    contexts[id] = ConfirmingInputMethod(client: field)
    test.addTeardownBlock { @MainActor in contexts[id] = nil }
  }

  private static func install() {
    guard !installed else { return }
    installed = true
    let selector = #selector(getter: NSView.inputContext)
    typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<NSTextInputContext>?
    let inherited = unsafeBitCast(
      class_getMethodImplementation(NSTextView.self, selector), to: Getter.self)
    let getter: @convention(block) (AnyObject) -> Unmanaged<NSTextInputContext>? = { view in
      if let context = contexts[ObjectIdentifier(view)] { return .passUnretained(context) }
      return inherited(view, selector)
    }
    class_addMethod(
      MessageTextView.self, selector, imp_implementationWithBlock(getter), "@@:")
  }

  override func handleEvent(_ event: NSEvent) -> Bool {
    guard let field = client as? NSTextView else { return false }
    if field.hasMarkedText() {
      let marked = (field.string as NSString).substring(with: field.markedRange())
      field.insertText(marked, replacementRange: NSRange(location: NSNotFound, length: 0))
    } else {
      field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }
    return true
  }
}
