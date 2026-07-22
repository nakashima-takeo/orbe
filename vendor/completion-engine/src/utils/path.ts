// node:path を JSC で使えないため、runtime が必要とする posix パス操作だけを最小実装する。
const SEP = "/";

export const posixIsAbsolute = (p: string): boolean => p.startsWith(SEP);

export const posixBasename = (p: string): string => {
  const trimmed = p.endsWith(SEP) ? p.slice(0, -1) : p;
  const idx = trimmed.lastIndexOf(SEP);
  return idx < 0 ? trimmed : trimmed.slice(idx + 1);
};

export const posixDirname = (p: string): string => {
  const trimmed = p.endsWith(SEP) && p.length > 1 ? p.slice(0, -1) : p;
  const idx = trimmed.lastIndexOf(SEP);
  if (idx < 0) return ".";
  if (idx === 0) return SEP;
  return trimmed.slice(0, idx);
};

export const posixJoin = (a: string, b: string): string => {
  if (b.startsWith(SEP)) return b;
  if (a.endsWith(SEP)) return a + b;
  return `${a}${SEP}${b}`;
};
