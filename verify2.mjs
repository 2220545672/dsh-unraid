import { readFileSync } from 'node:fs';
const fenceRe = /^```[^\n]*\n[\s\S]*?^```[^\n]*$/gm;
const jobs = [
  ['/workspace/unraid/dsh-unraid/docs/ca-submission.md', '/tmp/i18n/docs/ca-submission.zh-CN.md', '/tmp/i18n/docs/ca-submission.md'],
  ['/workspace/unraid/dsh-unraid/docs/ca-pitfalls.md', '/tmp/i18n/docs/ca-pitfalls.zh-CN.md', '/tmp/i18n/docs/ca-pitfalls.md'],
];
const stripComments = (f) => f.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
for (const [src, zh, en] of jobs) {
  const g = (p) => readFileSync(p, 'utf8').match(fenceRe) ?? [];
  const S = g(src), Z = g(zh), E = g(en);
  console.log(`\n== ${en.split('/').pop()} ==`);
  console.log(`  fences: ${S.length}`);
  console.log(`  zh fences byte-identical to source: ${JSON.stringify(S) === JSON.stringify(Z)}`);
  console.log(`  en non-comment fence lines byte-identical to source: ${JSON.stringify(S.map(stripComments)) === JSON.stringify(E.map(stripComments))}`);
  E.forEach((f, i) => {
    const removed = S[i].split('\n').filter((l) => /^\s*#/.test(l)).length;
    const added = f.split('\n').filter((l) => /^\s*#/.test(l)).length;
    console.log(`    fence ${i + 1}: comment lines src=${removed} en=${added}; non-comment lines src=${stripComments(S[i]).split('\n').length} en=${stripComments(f).split('\n').length}`);
    if (S[i].split('\n').length !== f.split('\n').length) console.log(`    note: total line count differs (${S[i].split('\n').length} -> ${f.split('\n').length})`);
  });
  const cjk = (p) => [...readFileSync(p, 'utf8').matchAll(/[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]+/g)].map((m) => m[0]);
  const enCjk = cjk(en);
  console.log(`  remaining CJK sequences in EN: ${enCjk.length ? JSON.stringify(enCjk) : 'none'}`);
}
