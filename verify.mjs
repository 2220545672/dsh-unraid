import { readFileSync } from 'node:fs';
const pairs = [
  ['/workspace/unraid/dsh-unraid/docs/ca-submission.md', '/tmp/i18n/docs/ca-submission.zh-CN.md', '/tmp/i18n/docs/ca-submission.md'],
  ['/workspace/unraid/dsh-unraid/docs/ca-pitfalls.md', '/tmp/i18n/docs/ca-pitfalls.zh-CN.md', '/tmp/i18n/docs/ca-pitfalls.md'],
];
const fenceRe = /^```[^\n]*\n[\s\S]*?^```[^\n]*$/gm;
for (const [src, zh, en] of pairs) {
  const f = (p) => readFileSync(p, 'utf8').match(fenceRe) ?? [];
  const [a, b, c] = [f(src), f(zh), f(en)];
  console.log(`${en.split('/').pop()}: fences en==src ${JSON.stringify(a) === JSON.stringify(c)}, fences zh==src ${JSON.stringify(a) === JSON.stringify(b)} (${a.length})`);
  const nums = (p) => (readFileSync(p, 'utf8').match(/\d[\d.,:/-]*/g) ?? []).join('|');
  const srcNums = nums(src), enNums = nums(en);
  const sh = (s) => s.split('|').sort().join('|');
  console.log(`  numeric tokens identical (as multiset): ${sh(srcNums) === sh(enNums)}  src=${srcNums.split('|').length} en=${enNums.split('|').length}`);
  if (sh(srcNums) !== sh(enNums)) {
    const cnt = (s) => s.split('|').reduce((m, x) => (m[x] = (m[x] ?? 0) + 1, m), {});
    const A = cnt(srcNums), B = cnt(enNums);
    for (const k of new Set([...Object.keys(A), ...Object.keys(B)])) if ((A[k] ?? 0) !== (B[k] ?? 0)) console.log(`   DIFF ${JSON.stringify(k)}: src ${A[k] ?? 0} en ${B[k] ?? 0}`);
  }
  const rows = (p) => (readFileSync(p, 'utf8').match(/^\|/gm) ?? []).length;
  console.log(`  table pipe-lines: src=${rows(src)} en=${rows(en)} zh=${rows(zh)}`);
  const heads = (p) => (readFileSync(p, 'utf8').match(/^#{1,6} /gm) ?? []).length;
  console.log(`  headings: src=${heads(src)} en=${heads(en)} zh=${heads(zh)}`);
  const links = (p) => (readFileSync(p, 'utf8').match(/\]\([^)]+\)/g) ?? []);
  console.log(`  links en: ${links(en).join(' ')}`);
  console.log(`  links zh: ${links(zh).join(' ')}`);
}
