import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

// v1.71 文件树拖拽移动与拖笔记进栏打开：三源断言（FileTreeView / Index / v2 原型）。
// 断言的是结构事实（回调、门控、合并策略、键值、落点），不是交互结果——
// 手势共存与 Web 上方 drop 触发是 API24 / XT2 实测项，见需求文档 §6。
const fileTree = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url), 'utf8');
const vaultSidebar = fs.readFileSync(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url), 'utf8');
const index = fs.readFileSync(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const prototype = fs.readFileSync(
  new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

test('71.1 main tree rows are draggable; referenceOnly keeps notes-only Agent behavior', () => {
  // 主树全行可拖（笔记 + 文件夹），Agent 引用树保持仅笔记行。
  assert.match(fileTree, /\.draggable\(!this\.referenceOnly \|\| !n\.isDir\)/);
  assert.doesNotMatch(fileTree, /\.draggable\(this\.referenceOnly && !n\.isDir\)/);
  // Agent 拖放零回归：extraInfo 分场景，payload 新增 isDir 不破坏旧解析（只读 vaultId/path）。
  assert.match(fileTree,
    /return \{ extraInfo: this\.referenceOnly \? '当前知识库笔记引用' : '拖动移动或打开' \};/);
  assert.match(fileTree,
    /JSON\.stringify\(\{ vaultId: this\.vaultId, path: n\.relPath, isDir: n\.isDir \}\)/);
});

test('71.1/71.3 folder-row drop target with self/descendant guard and highlight in LazyForEach keys', () => {
  // 行级与 List 级都接收 MIME；referenceOnly 树不接受任何落点。
  assert.match(fileTree, /\.allowDrop\(this\.referenceOnly \? null : \[NOTE_REF_MIME\]\)/);
  // 自身 / 子孙行不允许：事件回调里过滤（allowDrop 是渲染绑定，LazyForEach 键不变不重算）。
  assert.match(fileTree, /private canDropIntoDir\(node: TreeNode\): boolean/);
  assert.match(fileTree, /if \(this\.dragSourcePath === node\.relPath\) \{\s*return false;\s*\}/);
  assert.match(fileTree,
    /if \(this\.dragSourceIsDir && node\.relPath\.startsWith\(this\.dragSourcePath \+ '\/'\)\) \{\s*return false;\s*\}/);
  // 悬停高亮进目录行键值（faqs-arkui-219：不进键不刷新）。
  assert.match(fileTree, /\(this\.dropOverDir === n\.relPath \? '\|drop' : ''\)/);
  assert.match(fileTree, /this\.dropOverDir === n\.relPath \? \$r\('app\.color\.brand_bg'\)/);
});

test('71.1/71.3 multiple onDrop calls per drop are merged by rank and flushed once', () => {
  assert.match(fileTree, /private pendingMoveDest: string = '';/);
  assert.match(fileTree, /private pendingMoveRank: number = 0;/);
  assert.match(fileTree, /private requestDragMove\(destDir: string, rank: number\): void \{/);
  assert.match(fileTree, /if \(rank >= this\.pendingMoveRank\) \{/);
  assert.match(fileTree, /setTimeout\(\(\): void => \{ this\.flushPendingDragMove\(\); \}, 0\)/);
  // rank 语义：目录行(3) > 笔记行拦截(2) > 树根空白(1)；树根空白 = 移到库根。
  assert.match(fileTree, /this\.requestDragMove\(n\.relPath, 3\)/);
  assert.match(fileTree, /this\.requestDragMove\('', 2\)/);
  assert.match(fileTree, /this\.requestDragMove\('', 1\)/);
  assert.match(fileTree,
    /rank === 3[\s\S]*?this\.onDragMovePath\(this\.dragSourcePath, this\.dragSourceIsDir, destDir\)/);
  assert.match(fileTree,
    /rank === 1[\s\S]*?this\.onDragMovePath\(this\.dragSourcePath, this\.dragSourceIsDir, ''\)/);
});

test('71.2 drag session callbacks flow FileTreeView -> VaultSidebar -> Index', () => {
  for (const source of [fileTree, vaultSidebar]) {
    assert.match(source, /onDragMovePath: \(relPath: string, isDir: boolean, destDir: string\) => void/);
    assert.match(source, /onTreeDragStart: \(relPath: string, isDir: boolean\) => void/);
    assert.match(source, /onTreeDragEnd: \(\) => void = \(\) => \{\}/);
  }
  assert.match(vaultSidebar, /onDragMovePath: \(relPath: string, isDir: boolean, destDir: string\): void => \{\s*this\.onDragMovePath\(relPath, isDir, destDir\);/);
  assert.match(vaultSidebar, /onTreeDragStart: \(relPath: string, isDir: boolean\): void => \{\s*this\.onTreeDragStart\(relPath, isDir\);/);
  // Index 接线：拖拽会话记录 + 移动走带反馈的包装，不复用对话框静默路径。
  assert.match(index, /onTreeDragStart: \(relPath: string, isDir: boolean\): void => \{ this\.onTreeDragStart\(relPath, isDir\); \}/);
  assert.match(index, /void this\.doDragMovePath\(relPath, isDir, destDir\);/);
});

test('71.3 doMovePath reports the final path; drag move toasts rename-suffix outcomes', () => {
  assert.match(index,
    /private async doMovePath\(relPath: string, isDir: boolean, destDir: string\): Promise<string>/);
  assert.match(index, /return mutation\.path;/);
  assert.match(index,
    /private async doDragMovePath\(relPath: string, isDir: boolean, destDir: string\): Promise<void>/);
  // no-op（拖回原目录）与失败不提示；重名后缀时点名实际新路径。
  assert.match(index, /if \(actual\.length === 0 \|\| actual === relPath\) \{\s*return;\s*\}/);
  assert.match(index, /'已移动到「' \+ actual \+ '」'/);
  assert.match(index, /'目标已有同名，已移动为「' \+ actual \+ '」'/);
});

test('71.2 panes are drop targets with highlight, gated to note drags on dual-pane layouts', () => {
  assert.match(index, /const NOTE_REF_MIME: string = 'ApplicationDefinedType';/);
  assert.match(index, /@State paneDropOver: string = '';/);
  // 门控：仅笔记（文件夹拖拽不进栏）、单屏不响应栏落点、目标栏可见。
  assert.match(index, /private paneAcceptsTreeNoteDrag\(pane: string\): boolean \{/);
  assert.match(index,
    /if \(this\.treeDragPath\.length === 0 \|\| this\.treeDragIsDir \|\| this\.isSingleScreenLayout\(\)\) \{\s*return false;\s*\}/);
  assert.match(index, /return this\.notePaneVisible\(pane\);/);
  // drop = 该栏打开（复用 onSelectFile 链路并归还焦点）。
  assert.match(index, /this\.onSelectFile\(relPath, pane, true\);/);
  for (const pane of ['left', 'right']) {
    assert.match(index, new RegExp(
      `\\.onDragEnter\\(\\(event: DragEvent\\): void => \\{ this\\.onPaneDragEnter\\('${pane}'\\); \\}\\)`));
    assert.match(index, new RegExp(
      `\\.onDrop\\(\\(event: DragEvent\\): void => \\{ this\\.onPaneDrop\\('${pane}'\\); \\}\\)`));
    assert.match(index, new RegExp(
      `\\.border\\(\\{ width: 1, color: this\\.paneDropOver === '${pane}' \\? \\$r\\('app\\.color\\.brand'\\) : Color\\.Transparent \\}\\)`));
  }
  // v1.28 空态承诺「拖到这一栏打开」——本版落地后文案保持不变即准确。
  assert.match(index, /从文件列表选一篇，或拖到这一栏打开/);
});

test('v1.71 fix: ApplicationDefinedRecord drag type + pane shields reclaim Web drop zones (API26 emulator repro 2026-11-16)', () => {
  // 根因一：ApplicationDefinedRecord 的 summary 键恒为 'ApplicationDefinedType'（实测），
  // allowDrop 按 summary 键比对——任意「私有 MIME 串」永不匹配
  // （"target data is not allowed to fall into"）；allowDrop 必须写官方示例值。
  // 根因二：ArkWeb 原生接管栏内拖放，栏根 onDrop 收不到 Web 区域事件（"TargetNode is Web"）。
  const agent = fs.readFileSync(
    new URL('../../entry/src/main/ets/components/AgentWorkspace.ets', import.meta.url), 'utf8');
  for (const source of [fileTree, index, agent]) {
    assert.match(source, /const NOTE_REF_MIME: string = 'ApplicationDefinedType';/);
  }
  // 拖拽数据：官方 ApplicationDefinedRecord 构造形态（类型走 applicationDefinedType，JSON 走 rawData）。
  assert.match(fileTree, /new unifiedDataChannel\.ApplicationDefinedRecord\(\)/);
  assert.match(fileTree, /record\.applicationDefinedType = NOTE_REF_MIME;/);
  assert.match(fileTree, /record\.rawData = new util\.TextEncoder\(\)\.encodeInto\(payload\);/);
  // Agent 读取端：instanceof 分派 + rawData 解码，保留旧 (type, value) 形态回退。
  assert.match(agent, /private readNoteRefText\(records: unifiedDataChannel\.UnifiedRecord\[\]\): string/);
  assert.match(agent, /decodeToString\(record\.rawData\)/);
  // 两栏护盾：会话期间挂载（@State treeDragActive 驱动），容器末位抢在 ArkWeb 之前接管落点。
  assert.match(index, /@State treeDragActive: boolean = false;/);
  assert.equal((index.match(/if \(this\.treeDragActive\) \{/g) || []).length, 2);
  for (const pane of ['left', 'right']) {
    assert.match(index, new RegExp(
      `\\.backgroundColor\\(Color\\.Transparent\\)[\\s\\S]*?\\.allowDrop\\(\\[NOTE_REF_MIME\\]\\)[\\s\\S]*?` +
      `\\.onDrop\\(\\(event: DragEvent\\): void => \\{ this\\.onPaneDrop\\('${pane}'\\); \\}\\)`));
  }
});

test('71.5 prototype syncs whole-row drag source and keeps the tail icon click-only', () => {
  // 行按钮成为拖拽源（整行语义，替代行尾图标拖动）。
  assert.match(prototype,
    /<button class="tree-row file-row" draggable="true" style="--depth:'\+depth\+'"/);
  assert.match(prototype, /\$\('notes'\)\.querySelectorAll\('\.file-row\[data-note\]'\)\.forEach\(b=>\{b\.ondragstart/);
  // 行尾图标保留点击语义，不再是拖拽源。
  assert.match(prototype, /title="点击在另一栏打开" aria-pressed="/);
  assert.doesNotMatch(prototype, /class="file-reference" draggable="true"/);
  assert.doesNotMatch(prototype, /或拖到目标栏/);
  // 拖拽光标跟随行，不跟随图标。
  assert.match(prototype, /\.file-row\{cursor:grab\}/);
  assert.doesNotMatch(prototype, /\.file-reference\{cursor:grab\}/);
});
