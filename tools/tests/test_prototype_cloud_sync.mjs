/*
 * v1.99 华为云空间同步设计稿契约测试。
 *
 * 锁四件事：
 * 1. 原型结构 —— 云空间状态页（settings-page cloud-page 全屏范式）、库管理入口卡、页脚演示脚注；
 * 2. 状态四态 —— 未开启引导 / 已连接 / 同步中 / 失败（网络、云端未就绪）本地可渲染、入口卡联动；
 * 3. 新建库存储位置 —— 本机 / 华为云空间切换、未开启时禁用、创建结果 type:'cloud'；
 * 4. 红线 —— v1.99 CSS 只引用 token（无散写十六进制色）、URL 直达沿用 __initialViewCloud 模式。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const html = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

// v1.99 代码块：第二个 script 块内、Git 同步块之后（leftCloseNote 之后），便于行为测试单独执行。
const blockStart = html.indexOf('// v1.99: Huawei cloud sync status page.');
assert.ok(blockStart >= 0, 'prototype must contain the v1.99 cloud sync block');
const blockEndMarker = 'if(vaultManagerOpen)renderCloudEntry();';
const blockEnd = html.indexOf(blockEndMarker, blockStart);
assert.ok(blockEnd > blockStart, 'v1.99 block terminator found');
const cloudBlock = html.slice(blockStart, blockEnd + blockEndMarker.length);

test('cloud sync status page uses the full-screen page paradigm with demo footer', () => {
  assert.match(html, /class="settings-page cloud-page hidden"\s+id="cloudSyncPage"/);
  assert.match(html, /\.window\.cloud-open>\.sidebar,\.window\.cloud-open>\.workspace,\.window\.cloud-open>\.split-control\{display:none!important\}/);
  assert.match(html, /aria-labelledby="cloudSyncTitle"/);
  assert.match(html, /<h2 id="cloudSyncTitle">华为云空间同步<\/h2>/);
  assert.match(html, /id="cloudSyncContent"/);
  // 打开/关闭走 class 切换，不 showModal。
  assert.match(html, /\$\('window'\)\.classList\.add\('cloud-open'\)/);
  assert.match(html, /\$\('window'\)\.classList\.remove\('cloud-open'\)/);
  assert.ok(!/cloudSyncPage'\)\.showModal\(\)/.test(html), 'cloud page is not a modal dialog');
  // 演示脚注：五个状态演示按钮 + 明示不连接云空间、不读写文件。
  assert.match(html, /本页不连接华为云空间，不读写任何文件/);
  assert.match(html, /id="cloudSyncDemoLinks"/);
  for (const key of ['off', 'on', 'syncing', 'errNetwork', 'errCloud']) {
    assert.match(html, new RegExp(`data-cloud-demo="${key}"`));
  }
});

test('cloud entry card lives in the vault manager above the vault list', () => {
  const manager = html.match(/<section[^>]*id="vaultManagerPage"[\s\S]*?<\/section>/)[0];
  assert.match(manager, /class="cloud-entry" id="cloudEntryCard"/);
  assert.ok(manager.indexOf('cloudEntryCard') < manager.indexOf('vaultCards'),
    'entry card sits above the vault card list');
  // 库管理渲染后同步刷新入口卡（跨 script 块用 typeof 守卫，restoreUrl 先跑不炸）。
  assert.match(html, /if\(typeof renderCloudEntry==='function'\)renderCloudEntry\(\);/);
});

test('URL direct access mirrors the git sync __initialViewSync pattern', () => {
  assert.match(html, /if\(q\.get\('view'\)==='cloud'\)window\.__initialViewCloud=true/);
  assert.match(html, /if\(window\.__initialViewCloud\)openCloudSync\(\)/);
  assert.match(html, /view:\['notes','settings','vaults','sync','cloud'\]/);
  // restoreUrl 复位云空间页，避免从其它视图恢复时残留。
  assert.match(html, /\$\('window'\)\.classList\.remove\('cloud-open'\);\$\('cloudSyncPage'\)\.classList\.add\('hidden'\)/);
});

test('new-vault dialog offers a storage location segment (local default, cloud opt-in)', () => {
  assert.match(html, /<label class="hidden" id="vaultActionLocationField">存储位置/);
  assert.match(html, /id="vaultActionLocationSeg" role="group"/);
  assert.match(html, /aria-pressed="true" id="vaultLocationLocal"/);
  assert.match(html, /aria-pressed="false" id="vaultLocationCloud"/);
  // 只有新建模式显示存储位置；改名 / 删除隐藏。
  assert.match(html, /\$\('vaultActionLocationField'\)\.classList\.toggle\('hidden',!creating\)/);
  // 云空间未开启时禁用云选项并提示；创建结果按位置分叉 type / dir。
  assert.match(html, /\$\('vaultLocationCloud'\)\.disabled=!available/);
  assert.match(html, /需先在系统设置中开启华为云空间同步/);
  assert.match(html, /libraries\.push\(\{id,name:id,type:cloud\?'cloud':'local',dir:\(cloud\?'cloud\/':'vaults\/'\)\+id,files:0\}\)/);
  assert.match(html, /v\.type==='cloud'\?'华为云空间':'本地'/);
  // 目录提示按位置切换。
  assert.match(html, /'目录：'\+\(vaultCreateLocation==='cloud'\?'cloud\/':'vaults\/'\)\+candidate/);
});

test('v1.99 CSS only references tokens, never scattered colors', () => {
  const start = html.indexOf('/* v1.99: Huawei cloud sync status page.');
  const css = html.slice(start, html.indexOf('</style>', start));
  assert.ok(css.length > 500, 'v1.99 css block found');
  assert.doesNotMatch(css, /#[0-9a-fA-F]{3,8}\b/, 'no raw hex colors');
  for (const decl of css.match(/(?:background|color|border)[^;}]*/g) ?? []) {
    if (/var\(/.test(decl)) continue;
    assert.doesNotMatch(decl, /:\s*(?:rgb|hsl)[a-z()0-9,\s%]/i, `no raw color literals: ${decl}`);
  }
  assert.doesNotMatch(css, /font-size:\s*\d+px/);
});

// —— 行为测试：最小 DOM 桩 + 真实 v1.99 代码块 ——
function fixture(initial = {}) {
  const nodes = new Map();
  const get = (id) => {
    if (!nodes.has(id)) nodes.set(id, {
      id, innerHTML: '', textContent: '', value: '', title: '', disabled: false, open: false,
      dataset: {}, attrs: {}, onclick: null,
      classList: {
        values: new Set(),
        contains(k) { return this.values.has(k); },
        add(...ks) { ks.forEach((k) => this.values.add(k)); },
        remove(...ks) { ks.forEach((k) => this.values.delete(k)); },
        toggle(k, on) { const want = on === undefined ? !this.values.has(k) : !!on; if (want) this.values.add(k); else this.values.delete(k); return want; },
      },
      setAttribute(k, v) { this.attrs[k] = v; },
      focus() { this.focused = true; },
      addEventListener() {},
    });
    return nodes.get(id);
  };
  const pending = [];
  const ctx = {
    $: get,
    window: {},
    setTimeout: (fn) => { pending.push(fn); return 1; },
    clearTimeout() {},
    esc: (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'),
    libraries: initial.libraries ?? [
      { id: 'reading', name: '阅读笔记', type: 'git', dir: 'vaults/reading', files: 0 },
      { id: 'work', name: '工作笔记', type: 'cloud', dir: 'cloud/work', files: 0 },
    ],
    notes: initial.notes ?? [
      { id: 'a', vault: 'work', folder: '', title: '甲', text: '', deleted: false },
      { id: 'b', vault: 'work', folder: '', title: '乙', text: '', deleted: false },
      { id: 'c', vault: 'reading', folder: '', title: '丙', text: '', deleted: false },
    ],
    vaultManagerOpen: false,
    // 原型里 cloudSyncDemo 声明在块 0（新建对话框逻辑要读 enabled），这里直接注入等价状态。
    cloudSyncDemo: { enabled: true, status: 'idle', errorKind: 'network', lastSync: '10:32' },
    closeVaultManager() {}, openVaultManager() {},
    openVaultAction() {}, syncUrl() {},
    updateVaultActionHint() {},
  };
  ctx.vaultCreateLocation = 'local';
  const context = vm.createContext(ctx);
  const run = (s) => vm.runInContext(s, context);
  // block 0 的存储位置切换逻辑（引用同一份 cloudSyncDemo，必须先于行为断言装载）。
  const locStart = html.indexOf('function syncVaultCreateLocation()');
  assert.ok(locStart >= 0, 'syncVaultCreateLocation present');
  const locBlock = html.slice(locStart, html.indexOf('function openVaultAction(', locStart));
  run(locBlock);
  run(cloudBlock);
  // 进入已连接态的初始渲染（真实原型由 openCloudSync / 入口卡渲染触发）。
  run('renderCloudSync();renderCloudEntry();');
  return { get, run, context, flush() { while (pending.length) pending.shift()(); } };
}

test('connected state renders status, vault rows and notes; entry card agrees', () => {
  const f = fixture();
  assert.match(f.get('cloudSyncContent').innerHTML, /已连接华为云空间/);
  assert.match(f.get('cloudSyncContent').innerHTML, /id="cloudSyncNow"/);
  assert.match(f.get('cloudSyncContent').innerHTML, /上次同步 10:32 · 1 个云空间库/);
  assert.match(f.get('cloudSyncContent').innerHTML, /cloud-vault-row/);
  assert.match(f.get('cloudSyncContent').innerHTML, /cloud\/work · 2 篇笔记/);
  assert.match(f.get('cloudSyncContent').innerHTML, /使用注意/);
  assert.match(f.get('cloudEntryCard').innerHTML, /已连接/);
  assert.match(f.get('cloudEntryCard').innerHTML, /上次同步 10:32/);
});

test('disabled state shows the three-step guide and re-check flips to connected', () => {
  const f = fixture();
  f.get('cloudSyncDemoLinks').onclick({ target: { dataset: { cloudDemo: 'off' }, closest: null } });
  let content = f.get('cloudSyncContent').innerHTML;
  assert.match(content, /未开启华为云空间同步/);
  assert.match(content, /在这台设备上登录华为账号/);
  assert.match(content, /找到「曜石笔记」并开启同步/);
  assert.match(content, /id="cloudEnableCheck"/);
  assert.match(f.get('cloudEntryCard').innerHTML, /未开启/);
  f.get('cloudEnableCheck').onclick();
  content = f.get('cloudSyncContent').innerHTML;
  assert.match(content, /已连接华为云空间/);
  assert.match(content, /刚刚/);
  assert.match(f.get('cloudEntryCard').innerHTML, /已连接/);
});

test('manual sync runs the syncing state and settles back to connected', () => {
  const f = fixture();
  f.get('cloudSyncNow').onclick();
  let content = f.get('cloudSyncContent').innerHTML;
  assert.match(content, /正在同步…/);
  assert.match(f.get('cloudEntryCard').innerHTML, /同步中/);
  f.flush();
  content = f.get('cloudSyncContent').innerHTML;
  assert.match(content, /已连接华为云空间/);
  assert.match(content, /刚刚/);
  assert.match(f.get('cloudEntryCard').innerHTML, /已连接/);
});

test('failure states render cause-specific copy with a retry action', () => {
  const f = fixture();
  f.get('cloudSyncDemoLinks').onclick({ target: { dataset: { cloudDemo: 'errNetwork' }, closest: null } });
  let content = f.get('cloudSyncContent').innerHTML;
  assert.match(content, /上次同步失败：网络不可用/);
  assert.match(content, /系统会在网络恢复后自动重试/);
  assert.match(f.get('cloudEntryCard').innerHTML, /同步失败/);
  f.get('cloudSyncDemoLinks').onclick({ target: { dataset: { cloudDemo: 'errCloud' }, closest: null } });
  content = f.get('cloudSyncContent').innerHTML;
  assert.match(content, /上次同步失败：云端暂未就绪/);
  assert.match(content, /打开「曜石笔记」的同步开关/);
  assert.match(content, /id="cloudSyncNow"/);
});

test('cloud location option is disabled while cloud sync is off, available once enabled', () => {
  const f = fixture();
  f.get('cloudSyncDemoLinks').onclick({ target: { dataset: { cloudDemo: 'off' }, closest: null } });
  // 新建对话框打开时刷新可用性：未开启 → 云选项禁用，切到 cloud 被守卫拦下，仍停在本机。
  f.run('syncVaultCreateLocation()');
  assert.equal(f.get('vaultLocationCloud').disabled, true);
  assert.match(f.get('vaultLocationCloud').title, /需先在系统设置中开启华为云空间同步/);
  f.run("setVaultCreateLocation('cloud')");
  assert.equal(f.run('vaultCreateLocation'), 'local');
  // 开启后：切换生效，标题 / 目录提示联动，aria-pressed 互换。
  f.get('cloudSyncDemoLinks').onclick({ target: { dataset: { cloudDemo: 'on' }, closest: null } });
  f.run('syncVaultCreateLocation()');
  assert.equal(f.get('vaultLocationCloud').disabled, false);
  f.run("setVaultCreateLocation('cloud')");
  assert.equal(f.run('vaultCreateLocation'), 'cloud');
  assert.equal(f.get('vaultLocationCloud').attrs['aria-pressed'], 'true');
  assert.equal(f.get('vaultLocationLocal').attrs['aria-pressed'], 'false');
  // 回到本机恢复默认文案。
  f.run("setVaultCreateLocation('local')");
  assert.equal(f.run('vaultCreateLocation'), 'local');
  assert.equal(f.get('vaultLocationCloud').attrs['aria-pressed'], 'false');
  assert.equal(f.get('vaultLocationLocal').attrs['aria-pressed'], 'true');
});
