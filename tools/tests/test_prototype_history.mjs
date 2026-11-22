/*
 * v2.2 版本历史（设计稿）契约测试。
 *
 * 锁三件事：
 * 1. 原型结构 —— 三个笔记级 ⋯ 菜单入口、两个 utility 弹窗、CSS 只用 token；
 * 2. 纯逻辑 —— 上限淘汰最旧、恢复先留档 preRestore、按笔记隔离、seed 三类来源；
 * 3. 红线 —— 永久删除清历史；URL 只携带 panel=history，笔记内容不进 URL。
 *
 * vm realm 出来的数组与主 realm 不同源，deepEqual 前先 JSON roundtrip
 * （做法同 test_prototype_favorites.mjs）。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'fs';
import vm from 'vm';

const html = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const plain = (value) => JSON.parse(JSON.stringify(value));

function makeEl() {
  return {
    innerHTML: '', textContent: '', disabled: false, scrollTop: 0, open: false,
    showModal() { this.open = true; },
    close() { this.open = false; },
    querySelectorAll() { return []; }
  };
}

function makeContext(overrides = {}) {
  const els = {};
  const $ = (id) => (els[id] ||= makeEl());
  const context = vm.createContext({
    notes: [
      { id: 'a', vault: 'v1', deleted: false, title: 'A', text: 'now' },
      { id: 'b', vault: 'v1', deleted: false, title: 'B', text: 'other' }
    ],
    toasts: [], renders: 0, markdowns: [],
    $
  });
  context.toast = (message) => { context.toasts.push(message); };
  context.render = () => { context.renders += 1; };
  context.renderMarkdown = (text) => { context.markdowns.push(text); return '<p>' + text + '</p>'; };
  Object.assign(context, overrides);
  const start = html.indexOf('/* v2.2 版本历史——状态与逻辑 */');
  const end = html.indexOf('/* v2.2 版本历史——DOM 接线 */');
  assert.ok(start >= 0 && end > start, 'could not find history logic slice');
  vm.runInContext(html.slice(start, end), context);
  return context;
}

test('v2 note-level menus and dialogs expose version history', () => {
  // 三个入口：单屏更多菜单（图标 + 标签）、桌面左右栏 ⋯ 菜单（纯文字行）。
  assert.ok(html.includes('id="mobileHistory"'));
  assert.ok(html.includes('<span class="menu-label">版本历史</span>'));
  assert.ok(html.includes('<button id="leftHistory">版本历史</button>'));
  assert.ok(html.includes('<button id="rightHistory">版本历史</button>'));
  // 两个 utility 弹窗：列表 + 只读预览（预览复用 trash-preview 范式）。
  assert.ok(html.includes('<dialog id="historyDialog" class="utility-dialog"'));
  assert.ok(html.includes('<h2 id="historyTitle">版本历史</h2>'));
  assert.ok(html.includes('<dialog id="historyPreviewDialog" class="utility-dialog trash-preview-dialog"'));
  assert.ok(html.includes('<button id="saveVersion" type="button">保存当前版本</button>'));
  assert.ok(html.includes('<button id="deleteHistoryPreview" type="button" class="danger-text">删除此版本</button>'));
  assert.ok(html.includes('<button id="restoreHistoryPreview" class="primary" type="button">恢复此版本</button>'));
});

test('history wiring: menus, disabled states, sheet shell, escape guard, URL state', () => {
  // 菜单点击跟随各自栏内笔记；无笔记时禁用（updatePaneChrome 刷新链）。
  assert.ok(html.includes("$('mobileHistory').onclick=()=>{$('mobileMore').open=false;if(activeNoteId())openHistory(activeNoteId());};"));
  assert.ok(html.includes("$('leftHistory').onclick=()=>{$('leftMore').open=false;if(current)openHistory(current);};"));
  assert.ok(html.includes("$('rightHistory').onclick=()=>{$('rightMore').open=false;if(reference)openHistory(reference);};"));
  assert.ok(html.includes("$('mobileHistory').disabled=!activeNoteId();$('leftHistory').disabled=!current;$('rightHistory').disabled=!reference;"));
  // 手机端 sheet 定位（resize + open 时）与快捷键守卫。
  assert.ok(html.includes("'trashPreviewDialog','historyDialog','historyPreviewDialog','vaultActionDialog'];"));
  assert.ok(html.includes("'trashPreviewDialog','historyDialog','historyPreviewDialog','vaultActionDialog']){const d=document.getElementById(id);"));
  assert.ok(html.includes("$('trashDeleteDialog').open||$('trashPreviewDialog').open||$('historyDialog').open||$('historyPreviewDialog').open)return;"));
  // URL：panel 链、枚举、restoreUrl 分支与关闭循环。
  assert.ok(html.includes("$('historyDialog').open?'history':"));
  assert.ok(html.includes("panel:['none','share','trash','format','fileaction','search','history','mismatch']"));
  assert.ok(html.includes("else if(!settingsOpen&&panel==='history'&&current){openHistory(current);}"));
  assert.ok(html.includes("'trashPreviewDialog','historyDialog','historyPreviewDialog','imageViewerDialog','formatDialog'"));
  // 红线：笔记内容不进 URL —— 快照数据不进任何 put() 调用；panel=history 只是面板枚举值
  // （既有 put('history',…) 属设置页历史面板，与本特性无关）。
  assert.doesNotMatch(html, /put\([^)]*(historyByNote|noteHistory|pendingHistoryNote)/);
});

test('history CSS uses design tokens only', () => {
  const chunks = html.split('}').filter((chunk) => chunk.includes('.history-'));
  assert.ok(chunks.length >= 10, 'expected a block of .history-* rules');
  for (const chunk of chunks) {
    assert.doesNotMatch(chunk, /#[0-9a-fA-F]{3,8}\b/, 'raw hex color in: ' + chunk);
    assert.doesNotMatch(chunk, /rgb\(|hsl\(/, 'raw color function in: ' + chunk);
    assert.doesNotMatch(chunk, /\b\d+px\b/, 'raw px value in: ' + chunk);
  }
  // 来源标签色映射：手动=品牌蓝、自动=muted、恢复前留档=danger 系。
  assert.ok(html.includes('.history-kind[data-kind="manual"]{color:var(--blue);background:var(--blue-soft)}'));
  assert.ok(html.includes('.history-kind[data-kind="auto"]{color:var(--muted);background:var(--outer)}'));
  assert.ok(html.includes('.history-kind[data-kind="preRestore"]{color:var(--danger);background:var(--diff-del-bg)}'));
});

test('history logic: cap eviction, restore snapshots first, manual save, isolation', () => {
  const context = makeContext();
  const run = (expr) => {
    const value = vm.runInContext(expr, context);
    return value === undefined ? undefined : plain(value);
  };

  // 上限淘汰最旧：超过 HISTORY_LIMIT=20 后最旧出列。
  assert.equal(run('HISTORY_LIMIT'), 20);
  run('for(let i=0;i<25;i++)pushHistory("a","manual","v"+i);');
  const after = run('noteHistory("a").map(h=>h.text)');
  assert.equal(after.length, 20);
  assert.equal(after[0], 'v5');
  assert.equal(after[19], 'v24');

  // 按笔记隔离：b 不受 a 影响。
  assert.deepEqual(run('noteHistory("b")'), []);

  // seed：首次 openHistory 自动补三类演示版本（manual / auto / preRestore）。
  run('openHistory("b")');
  const kinds = plain(vm.runInContext('noteHistory("b").map(h=>h.kind)', context));
  assert.deepEqual(kinds, ['manual', 'auto', 'preRestore']);
  assert.equal(run('historyKindLabel("manual")'), '手动保存');
  assert.equal(run('historyKindLabel("auto")'), '自动保存');
  assert.equal(run('historyKindLabel("preRestore")'), '恢复前留档');
  assert.equal(run('historyWhen(Date.now())'), '刚刚');

  // 恢复语义：先把当前内容留档 preRestore，再写入目标版本文本。
  const before = run('noteHistory("b").length');
  const target = run('noteHistory("b")[2].text');
  vm.runInContext('restoreHistoryVersion(2)', context);
  const restored = plain(vm.runInContext('notes.find(n=>n.id==="b")', context));
  assert.equal(restored.text, target);
  const afterRestore = run('noteHistory("b")');
  assert.equal(afterRestore.length, before + 1);
  assert.equal(afterRestore[afterRestore.length - 1].kind, 'preRestore');
  assert.equal(afterRestore[afterRestore.length - 1].text, 'other');
  assert.equal(context.renders, 1);
  assert.equal(context.toasts.at(-1).includes('已恢复到'), true);

  // 手动保存：把当前内容存为 manual 快照。
  vm.runInContext('saveCurrentVersion()', context);
  const saved = run('noteHistory("b")');
  assert.equal(saved[saved.length - 1].kind, 'manual');
  assert.equal(saved[saved.length - 1].text, target);
});

test('purging a note clears its version history', () => {
  // purgeOne（单删与清空回收站共用）在移出 notes 的同时清掉该笔记的历史。
  assert.ok(html.includes('notes.splice(index,1);delete historyByNote[id];if(deletedUndo===id)deletedUndo=null;}'));
  const context = makeContext();
  const run = (expr) => plain(vm.runInContext(expr, context));
  run('pushHistory("a","manual","t1");pushHistory("b","manual","t2");');
  // 模拟 purgeOne 内的清理语句（逻辑与结构断言互补）。
  vm.runInContext('delete historyByNote["a"];', context);
  assert.deepEqual(run('noteHistory("a")'), []);
  assert.equal(run('noteHistory("b").length'), 1);
});
