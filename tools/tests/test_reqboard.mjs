// 需求看板（tools/reqboard）核心逻辑测试。
// 用临时目录做 fixture 仓库（REQBOARD_ROOT 覆盖），覆盖：表格解析、行状态分类、
// 乐观锁写回、版本索引解析、排期注记追加、§3 插入点、EOL 保留。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'reqboard-test-'));
process.env.REQBOARD_ROOT = ROOT;

// 动态 import：必须先设好 REQBOARD_ROOT 再加载 parse.mjs。
const P = await import('../reqboard/parse.mjs');

const BACKLOG = 'docs/requirements_backlog.md';
const README = 'docs/releases/README.md';
const QUICK = 'docs/releases/历史版本速查.md';
const ARCHIVE = 'docs/releases/历史版本归档.md';
const QUEUE = 'docs/releases/实施总清单.md';
const CHANGELOG = 'changelog.json';

function writeFile(rel, text) {
  const abs = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text, 'utf8');
}

// CRLF fixture：验证混合 EOL 场景下写回不破坏原格式。
const backlogText = [
  '# 需求池（fixture）',
  '',
  '## A. 编辑器',
  '',
  '| 需求点 | 价值 | 成本 | 依赖 | MVP 建议 |',
  '| --- | --- | --- | --- | --- |',
  '| 富文本编辑 | 核心体验 | 高 | — | ✓ 已在 MVP |',
  '| 表格编辑 | 常用 | 中 | 富文本编辑 | 未分配版本 |',
  '| 白板画布 | 低频 | 高 | — | ✗ 已放弃 |',
  '| 括号补全 | 顺手 | 低 | — | 2026-11-01 分配 [v1.49](releases/v1.49/需求文档.md) |',
  '',
  '## B. 同步',
  '',
  '| 需求点 | 价值 | 成本 | 依赖 | 状态 |',
  '| --- | --- | --- | --- | --- |',
  '| WebDAV 同步 | 多端 | 高 | v1.30 停靠格式栏 | 未分配版本 |',
  '| Git 子模块 | 少见 | 高 | — | 结论关闭：与沙箱库模型冲突 |',
  '',
].join('\r\n');

writeFile(BACKLOG, backlogText);

const readmeText = [
  '# 版本化开发规则（fixture）',
  '',
  '## 4. 版本索引',
  '',
  '| 版本 | 状态 | 对应里程碑 | 一句话定位 | 需求文档 |',
  '| --- | --- | --- | --- | --- |',
  '| v0.1 | ✅ 已发布（M0 骨架） | M0 | 骨架 | [需求文档](历史版本归档.md#v01-需求文档) |',
  '| v1.49 | 🟡 开发中 | M9 | 需求看板 | [需求文档](v1.49/需求文档.md) |',
  '',
].join('\n');

writeFile(README, readmeText);

writeFile(
  'docs/releases/v1.49/需求文档.md',
  [
    '# v1.49 需求文档',
    '',
    '> 状态：开发中',
    '',
    '## 1. 版本定位',
    'fixture',
    '',
    '## 2. 完成判定',
    'fixture',
    '',
    '## 3. 需求清单',
    '- 原有条目',
    '',
    '## 4. 明确不做',
    '无',
    '',
  ].join('\n')
);

writeFile(
  QUICK,
  [
    '# 速查（fixture）',
    '',
    '| 版本 | 对应里程碑 | 一句话定位 | 状态摘要 | 证据 |',
    '| --- | --- | --- | --- | --- |',
    '| v0.1 | M0 | 骨架 | 已发布 | E1 |',
  ].join('\n')
);

writeFile(ARCHIVE, '# 归档（fixture）\n\n## v0.1 需求文档\n\n内容\n\n## v0.9 需求文档\n\n内容\n');

writeFile(
  QUEUE,
  [
    '# 总清单（fixture）',
    '',
    '- [ ] [v1.60](v1.60/需求文档.md)：下一个版本（排队）',
    '- [x] [v1.49](v1.49/需求文档.md)：看板',
  ].join('\n')
);

writeFile(CHANGELOG, JSON.stringify({ entries: [{ version: 'v0.1', date: '2026-10-01', status: 'released', title: '骨架' }] }));

test('splitRowCells 处理转义竖线与首尾竖线', () => {
  assert.deepEqual(P.splitRowCells('| a \\| b | c |'), ['a | b', 'c']);
  assert.deepEqual(P.splitRowCells('  x |  y  '), ['x', 'y']);
  assert.equal(P.escapeCell('a|b\nc'), 'a\\|b c');
});

test('isSeparatorLine 只认表格分隔行', () => {
  assert.ok(P.isSeparatorLine('| --- | --- |'));
  assert.ok(P.isSeparatorLine('|:---|---:|'));
  assert.ok(!P.isSeparatorLine('| a | b |'));
  assert.ok(!P.isSeparatorLine('--- 正文分隔线 ---'));
});

test('classifyRow：状态分类口径', () => {
  // 已在 MVP
  assert.equal(P.classifyRow(['富文本编辑', '核心体验', '高', '—', '✓ 已在 MVP']).status, 'mvp');
  // 未分配 → pool；依赖列出现 vX.Y 不算排期
  assert.equal(P.classifyRow(['WebDAV 同步', '多端', '高', 'v1.30 停靠格式栏', '未分配版本']).status, 'pool');
  // 备注列有版本引用 → assigned
  const a = P.classifyRow(['括号补全', '顺手', '低', '—', '2026-11-01 分配 [v1.49](releases/v1.49/需求文档.md)']);
  assert.equal(a.status, 'assigned');
  assert.deepEqual(a.versions, ['v1.49']);
  // 关闭优先于版本引用
  const c = P.classifyRow(['Git 子模块', '少见', '高', '—', '结论关闭：v1.33 提过但放弃']);
  assert.equal(c.status, 'closed');
  // 无版本、无关键词 → pool
  assert.equal(P.classifyRow(['表格编辑', '常用', '中', '富文本编辑', '未分配版本']).status, 'pool');
});

test('parseBacklog：章节分组、行号、原始行、状态', () => {
  const b = P.parseBacklog(BACKLOG);
  assert.equal(b.sections.length, 2);
  assert.equal(b.sections[0].title, 'A. 编辑器');
  assert.equal(b.sections[1].title, 'B. 同步');
  const rowsA = b.sections[0].tables[0].rows;
  assert.deepEqual(rowsA.map((r) => r.status), ['mvp', 'pool', 'closed', 'assigned']);
  assert.deepEqual(rowsA[3].versions, ['v1.49']);
  // raw 与文件行一致（不含 EOL）
  const fileLines = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8').split(/\r\n/);
  assert.equal(rowsA[0].raw, fileLines[rowsA[0].line - 1]);
});

test('applyEdits：expect 不匹配整体失败且不写盘', () => {
  const before = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8');
  assert.throws(
    () => P.applyEdits(BACKLOG, [{ type: 'replace', line: 8, expect: '| 错误预期 |', content: '| x |' }]),
    /内容与预期不一致/
  );
  assert.equal(fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8'), before);
});

test('applyEdits：replace / insertAfter / delete 保留 CRLF', () => {
  const doc = P.readDocLines(BACKLOG);
  assert.equal(doc.eol, '\r\n');
  const line8 = P.lineContent(doc.rawLines[7]);
  P.applyEdits(BACKLOG, [
    { type: 'replace', line: 8, expect: line8, content: '| 表格编辑 | 常用 | 中 | 富文本编辑 | 未分配版本（改） |' },
  ]);
  const after = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8');
  assert.ok(after.includes('未分配版本（改） |\r\n'));
  P.applyEdits(BACKLOG, [{ type: 'insertAfter', line: 8, content: '| 新插入行 | 测试 | 低 | — | 未分配版本 |' }]);
  P.applyEdits(BACKLOG, [{ type: 'delete', line: 9, expect: '| 新插入行 | 测试 | 低 | — | 未分配版本 |' }]);
  const restored = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8');
  assert.ok(restored.includes('未分配版本（改） |\r\n'));
  assert.ok(!restored.includes('新插入行'));
});

test('parseVersionIndex / parseQuickIndex / parseArchivedVersions / scanVersionDirs', () => {
  const idx = P.parseVersionIndex(README);
  assert.equal(idx.length, 2);
  assert.equal(idx[0].version, 'v0.1');
  assert.equal(idx[0].statusKey, 'released');
  assert.equal(idx[0].docPath, 'docs/releases/历史版本归档.md');
  assert.ok(idx[0].archived);
  assert.equal(idx[1].version, 'v1.49');
  assert.equal(idx[1].statusKey, 'progress');
  assert.equal(idx[1].docPath, 'docs/releases/v1.49/需求文档.md');

  const quick = P.parseQuickIndex(QUICK);
  assert.equal(quick.length, 1);
  assert.equal(quick[0].version, 'v0.1');
  assert.equal(quick[0].summary, '已发布');

  const arch = P.parseArchivedVersions(ARCHIVE);
  assert.deepEqual(arch, ['v0.1', 'v0.9']);

  const dirs = P.scanVersionDirs('docs/releases');
  assert.equal(dirs.length, 1);
  assert.equal(dirs[0].version, 'v1.49');
  assert.equal(dirs[0].statusKey, 'progress');
  assert.equal(dirs[0].docPath, 'docs/releases/v1.49/需求文档.md');
});

test('parseQueue / parseChangelog / classifyVersionStatus / compareVersions / suggestNextVersion', () => {
  const q = P.parseQueue(QUEUE);
  assert.equal(q.length, 1);
  assert.equal(q[0].version, 'v1.60');

  const ch = P.parseChangelog(CHANGELOG);
  assert.equal(ch.length, 1);
  assert.equal(ch[0].version, 'v0.1');
  assert.equal(ch[0].status, 'released');

  assert.equal(P.classifyVersionStatus('🔒 已冻结'), 'frozen');
  assert.equal(P.classifyVersionStatus('✅ 已发布'), 'released');
  assert.equal(P.classifyVersionStatus('已关闭'), 'closed');
  assert.equal(P.classifyVersionStatus('⚪ 规划中'), 'planning');
  assert.equal(P.classifyVersionStatus('🟡 开发中'), 'progress');
  assert.equal(P.classifyVersionStatus('任意未知文案'), 'progress');

  assert.ok(P.compareVersions('v0.9', 'v1.0') < 0);
  assert.ok(P.compareVersions('v1.49', 'v1.60') < 0);
  assert.equal(P.compareVersions('v1.2', 'v1.2'), 0);

  assert.equal(P.suggestNextVersion(['v0.9', 'v1.49', 'v1.60']), 'v1.61');
  assert.equal(P.suggestNextVersion([]), 'v1.0');
});

test('findSection3InsertLine：定位 §3 内容末尾', () => {
  const rel = 'docs/releases/v1.49/需求文档.md';
  const line = P.findSection3InsertLine(rel);
  const doc = P.readDocLines(rel);
  const lines = doc.rawLines.map(P.lineContent);
  assert.equal(lines[line - 1], '- 原有条目');
});

test('scanVersionDirs 兼容 `> **状态**：` 粗体写法', () => {
  writeFile(
    'docs/releases/v1.99/需求文档.md',
    ['# v1.99 需求文档', '', '> **状态**：🟡 开发中，待验收', '', '## 3. 需求清单', '- x', ''].join('\n')
  );
  const dirs = P.scanVersionDirs('docs/releases');
  const v = dirs.find((d) => d.version === 'v1.99');
  assert.equal(v.status, '🟡 开发中，待验收');
  assert.equal(v.statusKey, 'progress');
});

test('排期全流程：新版本脚手架 + README 索引行 + 需求池补记（端到端）', () => {
  // 1) 新版本文档
  const docRel = 'docs/releases/v1.61/需求文档.md';
  const content = P.buildVersionDoc({
    version: 'v1.61',
    milestone: 'M9',
    positioning: '测试版本',
    completion: '测试完成判定',
    items: [{ section: 'B. 同步', name: 'WebDAV 同步', value: '多端', cost: '高' }],
    date: '2026-11-22',
  });
  P.writeNewDoc(docRel, content);
  const dirs = P.scanVersionDirs('docs/releases');
  assert.ok(dirs.some((d) => d.version === 'v1.61' && d.statusKey === 'planning'));

  // 2) README 索引追加一行（在最后一行索引行之后）
  const idxRows = P.parseVersionIndex(README);
  const lastLine = Math.max(...idxRows.map((r) => r.line));
  P.applyEdits(README, [
    { type: 'insertAfter', line: lastLine, content: P.buildReadmeIndexRow({ version: 'v1.61', milestone: 'M9', positioning: '测试版本', date: '2026-11-22' }) },
  ]);
  const idx2 = P.parseVersionIndex(README);
  assert.equal(idx2[idx2.length - 1].version, 'v1.61');
  assert.equal(idx2[idx2.length - 1].statusKey, 'planning');

  // 3) 需求池行补记分配注记并写回
  const b = P.parseBacklog(BACKLOG);
  const row = b.sections[1].tables[0].rows.find((r) => r.name === 'WebDAV 同步');
  assert.equal(row.status, 'pool');
  const nextCells = P.appendAssignNote(row.cells, { version: 'v1.61', date: '2026-11-22' });
  P.applyEdits(BACKLOG, [{ type: 'replace', line: row.line, expect: row.raw, content: P.buildRowLine(nextCells) }]);

  // 4) 重新解析：状态变 assigned，版本归属正确，其余行不受影响
  const b2 = P.parseBacklog(BACKLOG);
  const row2 = b2.sections[1].tables[0].rows.find((r) => r.name === 'WebDAV 同步');
  assert.equal(row2.status, 'assigned');
  assert.deepEqual(row2.versions, ['v1.61']);
  const keep = b2.sections[0].tables[0].rows.find((r) => r.name === '括号补全');
  assert.deepEqual(keep.versions, ['v1.49']);
});

test('appendAssignNote：空单元格与既有备注拼接', () => {
  assert.deepEqual(
    P.appendAssignNote(['a', 'b', ''], { version: 'v1.2', date: '2026-01-01' }),
    ['a', 'b', '2026-01-01 分配 [v1.2](releases/v1.2/需求文档.md)（需求看板排期）']
  );
  const out = P.appendAssignNote(['a', '旧备注'], { version: 'v1.2', date: '2026-01-01' });
  assert.match(out[1], /^旧备注；2026-01-01 分配/);
});

test('buildRowLine 生成合法表格行', () => {
  const line = P.buildRowLine(['含|竖线', '普通', null]);
  assert.equal(line, '| 含\\|竖线 | 普通 |  |');
});
