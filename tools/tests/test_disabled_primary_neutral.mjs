import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.32 32.12：主按钮禁用态中性化 —— 统一 --line 底、--muted 字、不透明，
// 替换 32.1 的「禁用 45% 不透明度」（半透明蓝在深色下像可点）；危险按钮禁用同样处理。
// 次要操作禁用沿用 45%（原型 utility-actions 规则）；菜单项 / 设置行不是主按钮，保留原语义。
const read = (rel) => readSourceFile(new URL(rel, import.meta.url));
const shell = read('../../entry/src/main/ets/components/UtilityDialogShell.ets');
const agent = read('../../entry/src/main/ets/components/AgentWorkspace.ets');
const shareFile = read('../../entry/src/main/ets/components/ShareFilePreviewDialog.ets');
const shareImage = read('../../entry/src/main/ets/components/ShareImagePreviewDialog.ets');
const shareText = read('../../entry/src/main/ets/components/ShareTextPreviewDialog.ets');
const index = read('../../entry/src/main/ets/pages/Index.ets');
const settings = read('../../entry/src/main/ets/components/SettingsView.ets');
const prototype = read('../../docs/prototype/v2/index.html');

const actionStart = shell.indexOf('export function UtilityDialogAction(');
const action = shell.slice(actionStart);

test('shared dialog action neutralizes disabled primary and danger (32.12)', () => {
  // 2026-11-07 EM-B2 修复：enabled 为 Binding<boolean>（UIUtils.makeBinding 按回调传递），
  // 读取处一律 .value —— 官方 arkts-builder 限制 3：多参全局 @Builder 按值不触发动态渲染。
  // 主 / 危险禁用：--muted 字（text_tertiary）
  assert.match(action, /\.fontColor\(!enabled\.value && tone !== 'secondary'\s*\n\s*\? \$r\('app\.color\.text_tertiary'\)/);
  // 主 / 危险禁用：--line 底
  assert.match(action, /\.backgroundColor\(!enabled\.value && tone !== 'secondary'\s*\n\s*\? \$r\('app\.color\.line'\)/);
  // 不透明：主 / 危险禁用 opacity 1；次要禁用沿用 45%
  assert.match(action, /\.opacity\(!enabled\.value && tone === 'secondary' \? 0\.45 : 1\)/);
  assert.ok(!action.includes('.opacity(enabled ? 1 : 0.45)'), '32.1 的 45% 写法已替换');
  assert.match(action, /enabled: Binding<boolean>/);
  // 可用态样式不变：secondary=bg_secondary/text_primary，danger=danger，primary=brand/on_brand
  assert.match(action, /tone === 'secondary' \? \$r\('app\.color\.text_primary'\) : \$r\('app\.color\.on_brand'\)/);
  assert.match(action, /tone === 'danger' \? \$r\('app\.color\.danger'\) : \$r\('app\.color\.brand'\)/);
  // 原型规则对照
  assert.match(prototype,
    /\.primary:disabled,\.primary:disabled:hover,\.utility-dialog \.primary:disabled\{background:var\(--line\)!important;color:var\(--muted\)!important;opacity:1!important;filter:none\}/);
  assert.match(prototype, /\.utility-dialog:not\(\.import-dialog\) \.utility-actions button:disabled\{opacity:\.45\}/);
});

test('agent send button goes gray while disabled (32.12)', () => {
  const sendIdx = agent.indexOf("Button(this.running ? '执行中…' : '发送')");
  assert.ok(sendIdx >= 0, 'agent send button found');
  const send = agent.slice(sendIdx, agent.indexOf('.onClick(() => { void this.send(); })', sendIdx));
  assert.match(send, /\.fontColor\(!this\.running && this\.draft\.trim\(\)\.length > 0\s*\n\s*\? \$r\('app\.color\.on_brand'\) : \$r\('app\.color\.text_tertiary'\)\)/);
  assert.match(send, /\.backgroundColor\(!this\.running && this\.draft\.trim\(\)\.length > 0\s*\n\s*\? \$r\('app\.color\.brand'\) : \$r\('app\.color\.line'\)\)/);
  assert.match(send, /\.enabled\(!this\.running && this\.draft\.trim\(\)\.length > 0\)/);
});

test('share preview primary buttons go gray while busy (32.12)', () => {
  const cases = [
    [shareFile, /this\.sharing \|\| this\.preparing/, /!this\.sharing && !this\.preparing/],
    [shareImage, /this\.sharing \|\| this\.retrying/, /!this\.sharing && !this\.retrying/],
    [shareText, /this\.sharing \|\| this\.preparing/, /!this\.sharing && !this\.preparing/]
  ];
  for (const [source, busy, enabled] of cases) {
    assert.match(source, new RegExp(
      `\\.fontColor\\((${busy.source})\\s*\\n\\s*\\? \\$r\\('app\\.color\\.text_tertiary'\\) : \\$r\\('app\\.color\\.on_brand'\\)\\)`));
    assert.match(source, new RegExp(
      `\\.backgroundColor\\((${busy.source})\\s*\\n\\s*\\? \\$r\\('app\\.color\\.line'\\) : \\$r\\('app\\.color\\.brand'\\)\\)`));
    assert.match(source, enabled);
  }
});

test('menu items and settings rows keep their prototype disabled semantics (32.12)', () => {
  // 单屏菜单禁用项：0.4（原型 .mobile-top-more .menu-group>button:disabled{opacity:.4}）
  assert.match(index, /\.opacity\(isEnabled \? 1 : 0\.4\)/);
  assert.match(prototype, /\.mobile-top-more \.menu-group>button:disabled\{opacity:\.4\}/);
  // 设置操作行（复制构建提交号 / 导出当前知识库）不是主按钮：保留 0.4 行内弱化
  assert.match(settings, /\.opacity\(isBuildCommitKnown\(this\.buildCommitState\(\)\) \? 1 : 0\.4\)/);
  assert.match(settings, /\.opacity\(this\.exportBackupDisabled\(\) \? 0\.4 : 1\)/);
});
