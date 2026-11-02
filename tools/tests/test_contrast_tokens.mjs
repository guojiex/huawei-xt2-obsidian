/**
 * v1.10 基础无障碍 —— 对比度回归。
 *
 * 锁三件事：
 *  1. 测量函数本身正确（WCAG 相对亮度与对比度公式，用已知值校核）；
 *  2. 判定矩阵里所有 enforce 组合在浅色 / 深色下都达标（--check 退出码 0）；
 *  3. waived 组合必须带理由，且浅色 token 与唯一设计真源原型 v2 的 :root 变量逐值一致。
 *
 * 第 3 条为什么重要：waiver 的前提是「这些值来自设计稿，改它等于改设计」。
 * 一旦有人顺手改了 token 却没同步原型，waiver 就会变成藏问题的地方，
 * 所以直接把原型 CSS 变量值读出来比对。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { parseColor, flatten, contrastRatio, run, MATRIX } from '../generators/check_contrast.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const proto = readFileSync(join(repoRoot, 'docs/prototype/v2/index.html'), 'utf8');

test('relative luminance and contrast follow the WCAG formula', () => {
  assert.equal(contrastRatio([255, 255, 255], [0, 0, 0]).toFixed(2), '21.00');
  assert.equal(contrastRatio([0, 0, 0], [255, 255, 255]).toFixed(2), '21.00');
  // WCAG 2.1 参考值：#777777 on white ≈ 4.48
  const grey = parseColor('#777777');
  assert.ok(Math.abs(contrastRatio(grey, [255, 255, 255]) - 4.48) < 0.02);
  // 同色对比度恒为 1
  assert.equal(contrastRatio(parseColor('#123456'), parseColor('#123456')).toFixed(2), '1.00');
});

test('alpha foreground is composited over the background, not ignored', () => {
  // #80000000 = alpha 128/255 的黑 → 压在白底上接近中灰（128/255 不是精确的一半，允许 1 的舍入）
  const composited = flatten(parseColor('#80000000'), [255, 255, 255, 1]);
  assert.deepEqual(composited.slice(0, 3), [127, 127, 127]);
  const half = flatten(parseColor('#CC000000'), [255, 255, 255, 1]);
  assert.ok(half[0] < 70, 'alpha 越大越接近前景色本身');
  // 全不透明时不参与合成
  const solid = flatten(parseColor('#101010'), [255, 255, 255, 1]);
  assert.deepEqual(solid.slice(0, 3), [16, 16, 16]);
});

test('every waived combination carries a written reason', () => {
  for (const entry of MATRIX) {
    const [fg, bg, , , status = 'enforce', reason = ''] = entry;
    if (status === 'waived') {
      assert.ok(reason.length > 0, `${fg} on ${bg} 标了 waived 却没写理由`);
    }
  }
});

test('all enforced combinations pass in both light and dark schemes', () => {
  const result = run();
  for (const [scheme, data] of Object.entries(result)) {
    const broken = data.rows.filter((r) => r.status === 'enforce' && !r.pass);
    assert.deepEqual(
      broken.map((r) => `${r.fg} on ${r.bg} = ${r.ratio}`),
      [],
      `${scheme} 仍有未达标且未豁免的组合`
    );
  }
  // 深色危险色已单独补齐：深色底上必须达到正文 4.5
  const darkDanger = result.dark.rows.find((r) => r.fg === 'danger' && r.bg === 'bg_page' && r.kind === 'body');
  assert.ok(darkDanger.ratio >= 4.5, `深色 danger on bg_page = ${darkDanger.ratio}`);
});

test('--check exits 0 and the known design-level gaps stay recorded as waived', () => {
  const script = join(repoRoot, 'tools/generators/check_contrast.mjs');
  execFileSync(process.execPath, [script, '--check'], { stdio: 'pipe' });
  const result = run();
  const waived = Object.values(result).flatMap((d) => d.rows).filter((r) => r.status === 'waived' && !r.pass);
  // 设计层缺口确实存在且被记录（不是全 PASS 假装没问题）
  assert.ok(waived.length >= 5, `应有多个已记录的设计层缺口，实际 ${waived.length}`);
  for (const key of ['text_secondary', 'brand', 'danger']) {
    assert.ok(waived.some((r) => r.fg === key), `${key} 的浅色缺口应被记录`);
  }
});

test('light tokens still match the prototype v2 design source', () => {
  // 豁免的前提：这些值就是设计稿的值。原型改了而 token 没跟上，豁免就失效。
  const expectations = [
    ['text_primary', '--ink', '#202530'],
    ['text_secondary', '--muted', '#7c8390'],
    ['brand', '--blue', '#007dff'],
    ['brand_bg', '--blue-soft', '#eaf3ff'],
    ['danger', '--danger', '#cf4048'],
    ['success', '--green', '#35916d'],
    ['line', '--line', '#e7e9ed'],
    ['bg_card', '--paper', '#ffffff'],
    ['bg_navigation', '--nav', '#f5f6f8'],
    ['bg_page', '--outer', '#e9edf2']
  ];
  const light = JSON.parse(
    readFileSync(join(repoRoot, 'entry/src/main/resources/base/element/color.json'), 'utf8')
  ).color.reduce((acc, c) => Object.assign(acc, { [c.name]: c.value }), {});
  for (const [token, cssVar, expected] of expectations) {
    assert.equal(light[token].toLowerCase(), expected.toLowerCase(), `${token} 应与原型 ${cssVar} 一致`);
    const protoValue = expected === '#ffffff' ? '#fff' : expected;
    assert.ok(proto.includes(`${cssVar}:${protoValue}`), `原型 v2 应仍定义 ${cssVar}:${protoValue}`);
  }
});

test('dark scheme defines its own danger instead of reusing the light value', () => {
  const dark = JSON.parse(
    readFileSync(join(repoRoot, 'entry/src/main/resources/dark/element/color.json'), 'utf8')
  ).color.reduce((acc, c) => Object.assign(acc, { [c.name]: c.value }), {});
  const light = JSON.parse(
    readFileSync(join(repoRoot, 'entry/src/main/resources/base/element/color.json'), 'utf8')
  ).color.reduce((acc, c) => Object.assign(acc, { [c.name]: c.value }), {});
  assert.notEqual(dark.danger.toLowerCase(), light.danger.toLowerCase(),
    '深色 danger 不能沿用浅色值（原型 [data-theme=dark] 未定义 --danger，需自行补齐）');
});
