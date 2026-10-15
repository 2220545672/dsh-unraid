import { readFileSync, writeFileSync } from 'node:fs';

function fences(file) {
  const text = readFileSync(file, 'utf8');
  const out = [];
  const re = /^```[^\n]*\n[\s\S]*?^```[^\n]*$/gm;
  let m;
  while ((m = re.exec(text)) !== null) out.push(m[0]);
  return out;
}

const jobs = [
  ['/workspace/unraid/dsh-unraid/docs/ca-submission.md', '/tmp/i18n/docs/ca-submission.md'],
  ['/workspace/unraid/dsh-unraid/docs/ca-pitfalls.md', '/tmp/i18n/docs/ca-pitfalls.md'],
];

for (const [src, dst] of jobs) {
  const blocks = fences(src);
  let out = readFileSync(dst, 'utf8');
  const markers = [...out.matchAll(/^@@FENCE(\d+)@@$/gm)].map((m) => m[0]);
  if (markers.length !== blocks.length) {
    throw new Error(`${dst}: ${markers.length} markers vs ${blocks.length} fences`);
  }
  markers.forEach((marker, i) => {
    if (out.split(marker).length !== 2) throw new Error(`${dst}: marker ${marker} not unique`);
    out = out.replace(marker, blocks[i]);
  });
  if (out.includes('@@FENCE')) throw new Error(`${dst}: unreplaced marker`);
  writeFileSync(dst, out);
  console.log(`${dst}: spliced ${blocks.length} fences`);
}
