/*
 * v1.50 置顶（设计稿）契约测试。
 *
 * 锁四件事：
 * 1. 原型结构 —— 左滑操作条最前置顶切换（未置顶「置顶」/ 已置顶「已置顶」）、
 *    行内名字尾部 12px pin 标记（muted、不可点）、置顶组在同父层最前（高于目录行）；
 * 2. 纯逻辑 —— 按库隔离、最新置顶在前、切换幂等、URL 只序列化活动库；
 * 3. 红线 —— 删除 / 永久删除 / 清空回收站 / 改名 / 移动不自动清理置顶条目（50.4 陈旧条目留存）；
 * 4. 入口边界 —— 收藏行与回收站行无置顶入口；置顶按钮不走 data-file-action 通用绑定。
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

const pinSlice = () => html.slice(html.indexOf('function pinnedIds()'), html.indexOf('const FAV_TONES'));
const treeSlice = () => html.slice(html.indexOf('function fileRowHtml(n,depth){'), html.indexOf('function toggleFolder(key,open)'));

test('v2 pin state starts empty per vault and ships pinnedIds/isPinned/togglePin helpers', () => {
  assert.ok(html.includes('const pinnedByVault={};'));
  assert.ok(html.includes('function pinnedIds(){return pinnedByVault[activeVault]||[];}'));
  assert.ok(html.includes('function isPinned(id){return pinnedIds().includes(id);}'));
  assert.ok(html.includes("function togglePin(id){const n=notes.find(item=>item.id===id&&item.vault===activeVault&&!item.deleted);if(!n)return;"));
  // 切换即时重排 + URL 持久化 + toast；renderTree 重建即收回左滑条（原生 50.2「操作条收回」）。
  assert.ok(html.includes("renderTree();scheduleUrl('push');toast((removing?'已取消置顶：':'已置顶：')+n.title,false);}"));
});

test('file rows expose the pin toggle as the frontmost swipe action without data-file-action', () => {
  const bar = '<div class="file-actions" inert><button data-pin-note="\'+n.id+\'" aria-pressed="\'+pinned+\'">\'+(pinned?\'已置顶\':\'置顶\')+\'</button><button data-file-action="rename" data-action-note="\'+n.id+\'">改名</button><button data-file-action="move" data-action-note="\'+n.id+\'">移动</button><button class="delete-file" data-file-action="delete" data-action-note="\'+n.id+\'">删除</button></div>';
  assert.ok(html.includes(bar), 'swipe bar must lead with the pin toggle');
  const pinButton = bar.slice(bar.indexOf('<button data-pin-note'), bar.indexOf('<button data-file-action'));
  assert.ok(!pinButton.includes('data-file-action'), 'pin button must not ride the generic file-action binding');
  // 事件绑定独立于 data-file-action。
  assert.ok(html.includes("$('notes').querySelectorAll('[data-pin-note]').forEach(b=>b.onclick=e=>{e.stopPropagation();togglePin(b.dataset.pinNote);});"));
  // delete-ready 态非删除按钮（含置顶）全部隐藏，复用现有规则。
  assert.ok(html.includes('.file-entry.delete-ready .file-actions button:not(.delete-file){visibility:hidden}'));
});

test('pinned files render before folders within the same parent layer, then the rest', () => {
  const pinnedLoop = html.indexOf('for(const n of branch.files.filter(item=>isPinned(item.id))) html+=fileRowHtml(n,depth);');
  const folderLoop = html.indexOf('for(const [name,child] of branch.folders){');
  const restLoop = html.indexOf('for(const n of branch.files.filter(item=>!isPinned(item.id))) html+=fileRowHtml(n,depth);');
  assert.ok(pinnedLoop >= 0 && folderLoop > pinnedLoop && restLoop > folderLoop, 'treeHtml order must be pinned → folders → rest');
  // 置顶行名字尾部 12px pin 标记；未置顶行保持原名。
  assert.ok(html.includes("(pinned?'<span class=\"tree-name-wrap\"><span class=\"tree-name\">'+esc(n.title)+'</span><span class=\"tree-pin\" aria-hidden=\"true\">'+svg('pin')+'</span></span>':'<span class=\"tree-name\">'+esc(n.title)+'</span>')"));
  assert.ok(html.includes("pin:'<path d=\"M12 17v5\"/>"), 'icon registry must ship a pin icon');
  // 视觉 token：12px（--s3）、muted（tertiary）、名字尾部跟随收缩。
  assert.ok(html.includes('#notes .file-entry{--swipe-width:192px}'));
  assert.ok(html.includes('.tree-name-wrap{flex:1;min-width:0;display:flex;align-items:center;gap:var(--s1)}'));
  assert.ok(html.includes('.tree-name-wrap .tree-name{flex:0 1 auto}'));
  assert.ok(html.includes('.tree-pin{flex:none;display:grid;place-items:center;width:var(--s3);height:var(--s3);color:var(--muted)}'));
  assert.ok(html.includes('.tree-pin svg{width:var(--s3);height:var(--s3)}'));
});

test('keyboard reveal focuses the swipe bar head so the pin toggle is reachable', () => {
  const focuses = html.match(/querySelector\('\.file-actions button'\)\.focus\(\)/g) || [];
  assert.equal(focuses.length, 1, 'only the tree binding retargets focus to the swipe bar head');
  assert.ok(html.includes("b.closest('[data-file-wrap]').querySelector('.file-actions button').focus();"));
  // 收藏行的键盘聚焦仍指向改名按钮（无置顶入口）。
  assert.ok(html.includes("$('favList').querySelectorAll('[data-fav-open]').forEach(b=>{"));
  assert.ok(html.match(/function renderFavorites\(\)\{[^\n]*/)[0].includes("querySelector('[data-file-action]').focus();"));
});

test('pin state persists through the URL for the active vault only', () => {
  assert.ok(html.includes("const pinnedNow=pinnedByVault[activeVault];if(pinnedNow&&pinnedNow.length)put('pinned',JSON.stringify(pinnedNow));"));
  const urlPuts = html.match(/put\('pinned'/g) || [];
  assert.deepEqual(urlPuts, ["put('pinned'"]);
  // 恢复侧：坏值静默回退，未知 id 过滤掉（URL 里只剩活动库的合法条目）。
  assert.ok(html.includes("try{if(params.has('pinned')){const pins=JSON.parse(params.get('pinned'));const validIds=new Set(ids);if(Array.isArray(pins))pinnedByVault[activeVault]=pins.filter(id=>validIds.has(id));}}catch(_){}"));
});

test('delete, purge, rename and move flows never auto-clean pin entries (50.4)', () => {
  const bodies = [
    html.match(/function deleteFile\(id\)\{[^\n]*/)[0],
    html.match(/function purgeOne\(id\)\{[^\n]*/)[0],
    html.match(/function confirmPurgeTrash\(\)\{[^\n]*/)[0],
    html.slice(html.indexOf('function confirmFileAction(){'), html.indexOf('function openFolderShare(path)'))
  ];
  for (const body of bodies) assert.ok(body.length > 0 && !body.includes('pinnedByVault'), 'flow must not touch pin state');
  // 收藏行与回收站行都没有置顶入口。
  assert.ok(!html.match(/function renderFavorites\(\)\{[^\n]*/)[0].includes('data-pin-note'));
  assert.ok(!html.match(/function renderTrash\(\)\{[^\n]*/)[0].includes('data-pin-note'));
});

test('togglePin logic: per-vault isolation, newest first, idempotent, no-ops for deleted or foreign notes', () => {
  const context = vm.createContext({
    notes: [
      { id: 'a', vault: 'v1', deleted: false, title: 'A' },
      { id: 'b', vault: 'v1', deleted: false, title: 'B' },
      { id: 'c', vault: 'v1', deleted: true, title: 'C' },
      { id: 'd', vault: 'v2', deleted: false, title: 'D' }
    ],
    activeVault: 'v1',
    pinnedByVault: {},
    renderTreeCount: 0,
    toasts: [],
    urls: []
  });
  context.renderTree = () => { context.renderTreeCount += 1; };
  context.scheduleUrl = (method) => { context.urls.push(method); };
  context.toast = (message) => { context.toasts.push(message); };
  vm.runInContext(pinSlice(), context);
  const run = (expr) => plain(vm.runInContext(expr, context));

  assert.deepEqual(run('pinnedIds()'), []);
  assert.equal(run('isPinned("a")'), false);

  // 置顶：unshift 到最前 + toast + 重排 + URL push
  const before = context.renderTreeCount;
  vm.runInContext('togglePin("a")', context);
  assert.deepEqual(run('pinnedIds()'), ['a']);
  assert.equal(context.toasts.at(-1), '已置顶：A');
  assert.equal(context.renderTreeCount, before + 1);
  assert.equal(context.urls.at(-1), 'push');

  vm.runInContext('togglePin("b")', context);
  assert.deepEqual(run('pinnedIds()'), ['b', 'a']);

  // 取消置顶：立即移除并提示；重复置顶回到最前
  vm.runInContext('togglePin("a")', context);
  assert.deepEqual(run('pinnedIds()'), ['b']);
  assert.equal(context.toasts.at(-1), '已取消置顶：A');
  vm.runInContext('togglePin("a")', context);
  assert.deepEqual(run('pinnedIds()'), ['a', 'b']);
  assert.equal(context.toasts.at(-1), '已置顶：A');

  // 已删除 / 他库笔记不可置顶，无副作用
  const toastCount = context.toasts.length;
  vm.runInContext('togglePin("c")', context);
  vm.runInContext('togglePin("d")', context);
  assert.deepEqual(run('pinnedIds()'), ['a', 'b']);
  assert.equal(context.toasts.length, toastCount);

  // 切库隔离：v2 独立状态，切回 v1 保持
  vm.runInContext('activeVault = "v2"', context);
  assert.deepEqual(run('pinnedIds()'), []);
  vm.runInContext('togglePin("d")', context);
  assert.deepEqual(run('pinnedIds()'), ['d']);
  vm.runInContext('activeVault = "v1"', context);
  assert.deepEqual(run('pinnedIds()'), ['a', 'b']);

  // 陈旧条目（已删除笔记的置顶）留存不清理，查询无副作用
  vm.runInContext('pinnedByVault.v1 = ["ghost", "b"]', context);
  assert.deepEqual(run('pinnedIds()'), ['ghost', 'b']);
  assert.equal(run('isPinned("ghost")'), true);
});

test('treeHtml rendering: pinned row leads, carries the marker and the toggled label', () => {
  const context = vm.createContext({
    activeVault: 'v1',
    pinnedByVault: { v1: ['p1'] },
    current: '',
    reference: '',
    folderState: {},
    esc: (value) => String(value),
    svg: (name) => '<svg data-icon="' + name + '"></svg>',
    activeNoteId: () => '',
    isFavorite: () => false
  });
  context.renderTree = () => {};
  context.scheduleUrl = () => {};
  context.toast = () => {};
  vm.runInContext(pinSlice(), context);
  vm.runInContext(treeSlice(), context);
  const p1 = { id: 'p1', vault: 'v1', folder: '', title: 'Pinned', deleted: false };
  const f1 = { id: 'f1', vault: 'v1', folder: '', title: 'File1', deleted: false };
  const f2 = { id: 'f2', vault: 'v1', folder: 'docs', title: 'File2', deleted: false };
  context.branch = {
    folders: new Map([['docs', { folders: new Map(), files: [f2] }]]),
    files: [p1, f1]
  };
  const out = vm.runInContext('treeHtml(branch)', context);

  // 同父层顺序：置顶行 → 目录行（目录子层 f2 嵌在其 li 内）→ 其余文件行
  const pinnedAt = out.indexOf('data-note="p1"');
  const folderAt = out.indexOf('data-folder="v1/docs"');
  const nestedAt = out.indexOf('data-note="f2"');
  const restAt = out.indexOf('data-note="f1"');
  assert.ok(pinnedAt >= 0 && folderAt > pinnedAt && nestedAt > folderAt && restAt > nestedAt, `unexpected order: ${pinnedAt}/${folderAt}/${nestedAt}/${restAt}`);

  // 置顶行：名字尾部 pin 标记 + 已置顶按钮态；未置顶行：无标记 + 「置顶」按钮态
  const pinnedRow = out.slice(out.indexOf('data-file-wrap="p1"'), out.indexOf('data-file-wrap="f1"'));
  assert.ok(pinnedRow.includes('data-pin-note="p1" aria-pressed="true">已置顶</button>'));
  assert.ok(pinnedRow.includes('<span class="tree-pin" aria-hidden="true"><svg data-icon="pin"></svg></span>'));
  const restRow = out.slice(out.indexOf('data-file-wrap="f1"'));
  assert.ok(restRow.includes('data-pin-note="f1" aria-pressed="false">置顶</button>'));
  assert.ok(!restRow.includes('tree-pin'));
  assert.equal(out.split('tree-pin" aria-hidden').length - 1, 1, 'exactly one pin marker in this branch');
});
