/*
 * v1.62 置顶（设计稿）契约测试 —— 树外独立置顶区语义（2026-11-13 与原生对齐）。
 *
 * 锁五件事：
 * 1. 原型结构 —— 置顶区在收藏区上方（置顶 → 收藏 → 全部笔记）、per-vault 折叠态、
 *    种子与收藏重叠演示同框；置顶行复用 fav-* 行样式 + 行尾取消置顶按钮；
 * 2. 树内纯排序 —— 目录序不再因置顶重排（62.2）；树行保留左滑「置顶」入口与
 *    行尾 12px pin 标记（入口仍在树上，状态体现在置顶区）；
 * 3. 纯逻辑 —— 按库隔离、最新置顶在前、切换幂等、URL 只序列化活动库（pinned）+ 折叠态（pinOpen）；
 * 4. 红线 —— 删除 / 永久删除 / 清空回收站 / 改名 / 移动不自动清理置顶条目（50.4 陈旧条目留存）；
 * 5. 入口边界 —— 收藏行与回收站行无置顶入口；置顶区行用 data-pin-remove / data-swipe-commit="unpin"，
 *    不走树行的 data-pin-note 与 data-file-action 通用绑定。
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

test('v2 pin section sits above favorites with per-vault collapse state and demo seeds', () => {
  assert.match(html, /<details class="favorites-folder hidden" id="pinFolder">/);
  assert.match(html, /<summary class="fav-head" id="openPins" title="展开 \/ 收起当前知识库置顶">/);
  assert.ok(html.includes('<span class="fav-head-label">置顶</span><small id="pinCount"></small>'));
  assert.match(html, /aria-label="置顶的笔记" class="fav-list" id="pinList"/);
  // 同框顺序：置顶 → 收藏 → 「全部笔记」标签 → 目录树（用完整节点串定位，避开同名 CSS 规则）。
  assert.ok(html.indexOf('id="pinFolder"') < html.indexOf('id="favoritesFolder"'));
  assert.ok(html.indexOf('id="favoritesFolder"') < html.indexOf('<div class="tree-section-label"'));
  // 种子与收藏重叠（tob / idea / reading_stream 同时被收藏），演示置顶 + 收藏同框。
  assert.ok(html.includes("const pinnedByVault={local:['tob','idea'],reading:['reading_stream']};"));
  assert.ok(html.includes('const pinFolderState={local:true,reading:true};'));
  // render() 全链路刷新：置顶区在收藏区之前（renderStatsMenu 为 v1.59 并入）。
  assert.match(html, /renderVaultPicker\(\);renderTree\(\);renderTrash\(\);renderPins\(\);renderFavorites\(\);renderStatsMenu\(\);renderReference\(\);/);
  // 折叠态随 details toggle 持久化（与收藏区同款绑定）。
  assert.ok(html.includes("$('pinFolder').addEventListener('toggle',()=>{pinFolderState[activeVault]=$('pinFolder').open;scheduleUrl('push');});"));
});

test('pin section rows render with unpin swipe, end-of-row unpin button and empty state', () => {
  const renderPins = html.match(/function renderPins\(\)\{[^\n]*/)[0];
  assert.ok(renderPins, 'renderPins must exist');
  assert.ok(renderPins.includes("data-swipe-commit=\"unpin\""));
  assert.ok(renderPins.includes('aria-label="打开置顶的笔记：\'+esc(n.title)+\'，位于 \'+esc(n.folder||\'根目录\')+\'"'));
  assert.ok(renderPins.includes('<button class="delete-file fav-remove" data-pin-remove="\'+n.id+\'">取消置顶</button>'));
  assert.ok(renderPins.includes('<button class="fav-unstar" data-pin-remove="\'+n.id+\'" title="取消置顶" aria-label="取消置顶 \'+esc(n.title)+\'">\'+svg(\'pin\')+\'</button>'));
  assert.ok(renderPins.includes("'<p class=\"fav-empty\">还没有置顶的笔记</p>'"));
  // 空态自动收起 + 计数 + 区头标签；折叠态回写 details。
  assert.ok(renderPins.includes("$('pinFolder').classList.toggle('hidden',items.length===0);if(!items.length)pinFolderState[activeVault]=false;"));
  assert.ok(renderPins.includes("setAttribute('aria-label','置顶，'+items.length+' 篇笔记')"));
  assert.ok(renderPins.includes("$('pinFolder').open=pinFolderState[activeVault]===true;"));
  // 事件绑定独立：取消置顶按钮 / 打开笔记 / 左滑互斥与收藏行同款，但属性名互不串。
  assert.ok(renderPins.includes("$('pinList').querySelectorAll('[data-pin-remove]').forEach(b=>b.onclick=e=>{e.stopPropagation();togglePin(b.dataset.pinRemove);});"));
  assert.ok(renderPins.includes("$('pinList').querySelectorAll('[data-pin-open]').forEach(b=>{b.onclick=()=>{if(swipeSuppressed===b.dataset.note){swipeSuppressed=null;return;}selectNote(b.dataset.pinOpen);};"));
  assert.ok(renderPins.includes('bindFileSwipe(b);'));
  assert.ok(!renderPins.includes('data-pin-note'));
  assert.ok(!renderPins.includes('data-fav-open'));
  // 滑到底提交按 data-swipe-commit 分派：unpin 优先于 unfavorite。
  assert.ok(html.includes("if(button.dataset.swipeCommit==='unpin')togglePin(button.dataset.note);else if(button.dataset.swipeCommit==='unfavorite')toggleFavorite(button.dataset.note);else deleteFile(button.dataset.note);"));
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

test('tree keeps pure folder-first order regardless of pin status (62.2)', () => {
  // 树内不再因置顶重排：v1.50 的 pinned-first / rest 双循环必须消失。
  assert.ok(!html.includes('for(const n of branch.files.filter(item=>isPinned(item.id)))'));
  assert.ok(!html.includes('for(const n of branch.files.filter(item=>!isPinned(item.id)))'));
  // 目录行在前、文件行在后（v1.49 纯排序回归）。
  const folderLoop = html.indexOf('for(const [name,child] of branch.folders){');
  const fileLoop = html.indexOf('for(const n of branch.files) html+=fileRowHtml(n,depth);');
  assert.ok(folderLoop >= 0 && fileLoop > folderLoop, 'treeHtml order must be folders → files');
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

test('pin state persists through the URL for the active vault only (pinned + pinOpen)', () => {
  assert.ok(html.includes("const pinnedNow=pinnedByVault[activeVault];if(pinnedNow&&pinnedNow.length)put('pinned',JSON.stringify(pinnedNow));"));
  const pinnedPuts = html.match(/put\('pinned'/g) || [];
  assert.deepEqual(pinnedPuts, ["put('pinned'"]);
  // 恢复侧：坏值静默回退，未知 id 过滤掉（URL 里只剩活动库的合法条目）。
  assert.ok(html.includes("try{if(params.has('pinned')){const pins=JSON.parse(params.get('pinned'));const validIds=new Set(ids);if(Array.isArray(pins))pinnedByVault[activeVault]=pins.filter(id=>validIds.has(id));}}catch(_){}"));
  // 折叠态独立成键（与 favOpen 同款）。
  assert.ok(html.includes("put('pinOpen',$('pinFolder').open?1:0);"));
  assert.ok(html.includes("if(params.has('pinOpen'))pinFolderState[activeVault]=params.get('pinOpen')==='1';"));
  const pinOpenPuts = html.match(/put\('pinOpen'/g) || [];
  assert.deepEqual(pinOpenPuts, ["put('pinOpen'"]);
});

test('keyboard reveal focuses the swipe bar head so the pin toggle is reachable', () => {
  const focuses = html.match(/querySelector\('\.file-actions button'\)\.focus\(\)/g) || [];
  assert.equal(focuses.length, 1, 'only the tree binding retargets focus to the swipe bar head');
  assert.ok(html.includes("b.closest('[data-file-wrap]').querySelector('.file-actions button').focus();"));
  // 收藏行 / 置顶行的键盘聚焦指向改名按钮（首个 [data-file-action]）。
  assert.ok(html.match(/function renderFavorites\(\)\{[^\n]*/)[0].includes("querySelector('[data-file-action]').focus();"));
  assert.ok(html.match(/function renderPins\(\)\{[^\n]*/)[0].includes("querySelector('[data-file-action]').focus();"));
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
    renderPinsCount: 0,
    toasts: [],
    urls: []
  });
  context.renderTree = () => { context.renderTreeCount += 1; };
  context.renderPins = () => { context.renderPinsCount += 1; };
  context.scheduleUrl = (method) => { context.urls.push(method); };
  context.toast = (message) => { context.toasts.push(message); };
  vm.runInContext(pinSlice(), context);
  vm.runInContext(html.slice(html.indexOf('function visiblePins()'), html.indexOf('function renderPins()')), context);
  const run = (expr) => plain(vm.runInContext(expr, context));

  assert.deepEqual(run('pinnedIds()'), []);
  assert.equal(run('isPinned("a")'), false);

  // 置顶：unshift 到最前 + toast + 置顶区刷新 + 重排 + URL push
  const before = context.renderTreeCount;
  vm.runInContext('togglePin("a")', context);
  assert.deepEqual(run('pinnedIds()'), ['a']);
  assert.deepEqual(run('visiblePins().map(n=>n.id)'), ['a']);
  assert.equal(context.toasts.at(-1), '已置顶：A');
  assert.equal(context.renderPinsCount, 1);
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

  // 陈旧条目（已删除笔记的置顶）留存不清理（50.4），查询无副作用
  vm.runInContext('pinnedByVault.v1 = ["ghost", "b"]', context);
  assert.deepEqual(run('pinnedIds()'), ['ghost', 'b']);
  assert.equal(run('isPinned("ghost")'), true);
  // 可见集合过滤已删除条目，但状态本身不清。
  vm.runInContext('pinnedByVault.v1 = ["c", "b"]', context);
  assert.deepEqual(run('visiblePins().map(n=>n.id)'), ['b']);
});

test('treeHtml rendering: folders lead, pin status never reorders, marker stays on the pinned row', () => {
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
    files: [f1, p1]
  };
  const out = vm.runInContext('treeHtml(branch)', context);

  // 纯排序：目录行（含子层 f2）在前，文件行按原数组顺序 —— 置顶不改变 f1 → p1 顺序。
  const folderAt = out.indexOf('data-folder="v1/docs"');
  const nestedAt = out.indexOf('data-note="f2"');
  const restAt = out.indexOf('data-note="f1"');
  const pinnedAt = out.indexOf('data-note="p1"');
  assert.ok(folderAt >= 0 && nestedAt > folderAt && restAt > nestedAt && pinnedAt > restAt, `unexpected order: ${folderAt}/${nestedAt}/${restAt}/${pinnedAt}`);

  // 置顶行：名字尾部 pin 标记 + 已置顶按钮态；未置顶行：无标记 + 「置顶」按钮态
  const pinnedRow = out.slice(out.indexOf('data-file-wrap="p1"'));
  assert.ok(pinnedRow.includes('data-pin-note="p1" aria-pressed="true">已置顶</button>'));
  assert.ok(pinnedRow.includes('<span class="tree-pin" aria-hidden="true"><svg data-icon="pin"></svg></span>'));
  const restRow = out.slice(out.indexOf('data-file-wrap="f1"'), out.indexOf('data-file-wrap="p1"'));
  assert.ok(restRow.includes('data-pin-note="f1" aria-pressed="false">置顶</button>'));
  assert.ok(!restRow.includes('tree-pin'));
  assert.equal(out.split('tree-pin" aria-hidden').length - 1, 1, 'exactly one pin marker in this branch');
});
