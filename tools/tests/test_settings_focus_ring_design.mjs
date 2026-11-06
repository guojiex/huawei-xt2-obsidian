import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.8：程序化聚焦的非交互元素 —— 仅键盘遍历时显示品牌蓝焦点环。
// 原型规则：[tabindex="-1"]:focus{outline:none} / :focus-visible{outline:var(--focus) solid var(--blue)}。
// 原生映射：focusable(true) + focusBox（FocusBoxStyle 无圆角字段，--small-r 记为已知偏差）。
const settings = readSourceFile(
  new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const FOCUS_BOX = /\.focusBox\(\{\s*\n\s*strokeWidth: LengthMetrics\.vp\(2\),\s*\n\s*strokeColor: ColorMetrics\.resourceColor\(\$r\('app\.color\.brand'\)\)\s*\n\s*\}\)/;

test('all four settings headings carry the brand focus ring (32.8)', () => {
  // Kit 导入（@kit.ArkUI 导出 LengthMetrics / ColorMetrics，API 12+）
  assert.match(settings, /import \{ ColorMetrics, LengthMetrics, promptAction \} from '@kit\.ArkUI';/);
  assert.match(index, /import \{ ColorMetrics, LengthMetrics, promptAction, router \} from '@kit\.ArkUI';/);
  // 四个标题：focusable → focusBox → id → 程序化聚焦入口保持
  for (const category of ['general', 'data', 'about', 'feedback']) {
    const idIdx = settings.indexOf(`.id('settings-heading-${category}')`);
    assert.ok(idIdx > 0, `settings-heading-${category} id present`);
    const block = settings.slice(Math.max(0, idIdx - 300), idIdx);
    assert.match(block, /\.focusable\(true\)[\s\S]*$/);
    assert.match(block, FOCUS_BOX, `settings-heading-${category} has focusBox before id`);
    assert.match(settings,
      new RegExp(`focusCategoryHeading\\('${category}'\\);`));
  }
  // 读屏从标题开始：requestFocus 入口不变
  assert.match(settings, /requestFocus\('settings-heading-' \+ category\)/);
});

test('pane title rows follow the same focus ring rule (32.8)', () => {
  // v1.30 30.4 程序化聚焦的路径行（原型 #leftTitle / #referenceTitle tabindex="-1"）
  const idIdx = index.indexOf(`.id('pane-title-' + $$.pane)`);
  assert.ok(idIdx > 0, 'pane-title id present');
  const block = index.slice(Math.max(0, idIdx - 400), idIdx);
  assert.match(block, /v1\.30 30\.4：「完成编辑」后焦点移到该栏路径行/);
  assert.match(block, /\.focusable\(true\)/);
  assert.match(block, FOCUS_BOX, 'pane-title row has focusBox before id');
  // 程序化聚焦调用保持
  assert.match(index, /requestFocus\('pane-title-' \+ pane\)/);
});

test('prototype focus-visible rule matches the mapped tokens (32.8)', () => {
  // 原型：默认聚焦不描边，仅键盘遍历（:focus-visible）显示 2px 品牌蓝描边
  assert.match(prototype, /\[tabindex="-1"\]:focus\{outline:none\}/);
  assert.match(prototype,
    /\[tabindex="-1"\]:focus-visible\{outline:var\(--focus\) solid var\(--blue\)/);
  assert.match(prototype, /--focus:2px/);
  // 原型带 tabindex="-1" 的非交互元素与原生一一对应：四标题 + 左右栏笔记标题
  for (const id of ['settingsHeading-general', 'settingsHeading-data',
    'settingsHeading-about', 'settingsHeading-feedback', 'leftTitle', 'referenceTitle']) {
    assert.match(prototype, new RegExp(`id="${id}"[^>]*tabindex="-1"`),
      `${id} carries tabindex="-1" in prototype`);
  }
});
