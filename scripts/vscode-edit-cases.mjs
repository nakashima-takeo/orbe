// 新しいテキスト面の語の規則（⌥←→・⌥⌫⌦・ダブルクリックの語・⌘←）の正解を、VS Code の同じコード（monaco-editor の
// esm）を動かして作り、Swift のテストの表として標準出力へ書く。scripts/gen-vscode-edit-cases.sh から呼ぶ。
const base = Deno.env.get("MONACO");
const load = (path) => import(`${base}/esm/vs/editor/common/${path}`);
const { WordOperations } = await load("cursor/cursorWordOperations.js");
const { MoveOperations } = await load("cursor/cursorMoveOperations.js");
const { getMapForWordSeparators } = await load("core/wordCharacterClassifier.js");
const { Position } = await load("core/position.js");
const { Selection } = await load("core/selection.js");
const { SingleCursorState } = await load("cursorCommon.js");
const { Range } = await load("core/range.js");

const separators = "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/?";
const map = getMapForWordSeparators(separators, []);
const models = [
  ["foo.bar(baz)  qux", "  let x = a->b; // c", "\tif (a == b) {"],
  ["a  b\t\tc", "x=1,y=2", "--flag=value"],
  ["  ", "", "foo_bar baz-qux"],
  ["a.b.c", "(...)", "hello world  "],
  ["", "end"],
  ["{", "    return self.value", "}"],
];

const lines = [];
for (const model of models) {
  const text = model.join("\n");
  const m = {
    getLineContent: (n) => model[n - 1],
    getLineMaxColumn: (n) => model[n - 1].length + 1,
    getLineMinColumn: () => 1,
    getLineCount: () => model.length,
    getLineFirstNonWhitespaceColumn: (n) => {
      const i = model[n - 1].search(/[^ \t]/);
      return i < 0 ? 0 : i + 1;
    },
    getValueInRange: (r) => model[r.startLineNumber - 1].substring(r.startColumn - 1, r.endColumn - 1),
  };
  const offset = (line, column) => model.slice(0, line - 1).reduce((a, l) => a + l.length + 1, 0) + column - 1;
  const range = (r) => (r ? [offset(r.startLineNumber, r.startColumn), offset(r.endLineNumber, r.endColumn)] : []);
  const ctx = (p) => ({
    wordSeparators: map, model: m, selection: new Selection(p.lineNumber, p.column, p.lineNumber, p.column),
    whitespaceHeuristics: true, autoClosingDelete: "never", autoClosingBrackets: "never",
    autoClosingQuotes: "never", autoClosingPairs: { autoClosingPairsOpenByEnd: new Map() }, autoClosedCharacters: [],
  });
  for (let line = 1; line <= model.length; line++) {
    for (let column = 1; column <= model[line - 1].length + 1; column++) {
      const p = new Position(line, column);
      const left = WordOperations.moveWordLeft(map, m, p, 1, false);
      const right = WordOperations.moveWordRight(map, m, p, 2);
      const deleteLeft = WordOperations.deleteWordLeft(ctx(p), 0);
      const deleteRight = WordOperations.deleteWordRight(ctx(p), 2);
      const empty = new Range(line, column, line, column);
      const word = WordOperations.word(
        { wordSeparators: separators, wordSegmenterLocales: [] }, m,
        new SingleCursorState(empty, 0, 0, p, 0), false, p);
      const home = MoveOperations.moveToBeginningOfLine(null, m, new SingleCursorState(empty, 0, 0, p, 0), false);
      lines.push(
        `    .init(text: ${JSON.stringify(text)}, offset: ${offset(line, column)}, ` +
          `wordLeft: ${offset(left.lineNumber, left.column)}, wordRight: ${offset(right.lineNumber, right.column)}, ` +
          `deleteLeft: [${range(deleteLeft).map((x) => x).join(", ")}], ` +
          `deleteRight: [${range(deleteRight).join(", ")}], ` +
          `word: [${range(word.selection).join(", ")}], ` +
          `home: ${offset(home.position.lineNumber, home.position.column)}),`,
      );
    }
  }
}

console.log(`// swiftlint:disable file_length type_body_length

/// VS Code の編集の規則の正解——monaco-editor ${Deno.env.get("MONACO_VERSION")} の \`WordOperations\` と
/// \`MoveOperations\` を動かした結果（scripts/gen-vscode-edit-cases.sh が生成する。手で直さない）。位置はどれも本文の
/// オフセット。範囲は [始まり, 終わり]（消さないなら空）。
enum VSCodeEditCases {
  struct Case {
    let text: String
    let offset: Int
    let wordLeft: Int
    let wordRight: Int
    let deleteLeft: [Int]
    let deleteRight: [Int]
    let word: [Int]
    let home: Int
  }

  static let cases: [Case] = [
${lines.join("\n")}
  ]
}
// swiftlint:enable type_body_length`);
