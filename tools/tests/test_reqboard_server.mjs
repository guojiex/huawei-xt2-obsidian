// 需求看板 HTTP 服务端到端测试：临时 fixture 仓库 + 随机端口起真服务。
// 覆盖：GET 页面 / overview、行编辑乐观锁、排期（新建版本 + 追加既有版本 + 冻结拒绝）。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { test } from 'node:test';

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'reqboard-srv-'));
const PORT = 18000 + Math.floor(Math.random() * 2000);
const BASE = `http://127.0.0.1:${PORT}`;
const BACKLOG = 'docs/requirements_backlog.md';
const README = 'docs/releases/README.md';

function writeFile(rel, text) {
  const abs = path.join(ROOT, rel);
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text, 'utf8');
}

writeFile(
  BACKLOG,
  [
    '# 需求池（fixture）',
    '',
    '## A. 编辑器',
    '',
    '| 需求点 | 价值 | 成本 | 依赖 | MVP 建议 |',
    '| --- | --- | --- | --- | --- |',
    '| 括号补全 | 顺手 | 低 | — | 未分配版本 |',
    '| 行号开关 | 排版 | 低 | — | 未分配版本 |',
    '',
  ].join('\r\n')
);

writeFile(
  README,
  [
    '# 版本化开发规则（fixture）',
    '',
    '## 4. 版本索引',
    '',
    '| 版本 | 状态 | 对应里程碑 | 一句话定位 | 需求文档 |',
    '| --- | --- | --- | --- | --- |',
    '| v0.1 | ✅ 已发布 | M0 | 骨架 | [需求文档](历史版本归档.md#v01-需求文档) |',
    '',
  ].join('\n')
);

writeFile(
  'docs/releases/v0.2/需求文档.md',
  ['# v0.2 需求文档', '', '> 状态：开发中', '', '## 1. 版本定位', 'fixture', '', '## 2. 完成判定', 'fixture', '', '## 3. 需求清单', '- 原有条目', '', '## 4. 明确不做', '无', ''].join('\n')
);

writeFile(
  'docs/releases/v0.3/需求文档.md',
  ['# v0.3 需求文档', '', '> 状态：🔒 已冻结', '', '## 3. 需求清单', '- 冻结条目', ''].join('\n')
);

writeFile('docs/releases/历史版本速查.md', '# 速查（fixture）\n');
writeFile('docs/releases/历史版本归档.md', '# 归档（fixture）\n');
writeFile('docs/releases/实施总清单.md', '# 清单（fixture）\n');
writeFile('changelog.json', JSON.stringify({ entries: [] }));

const child = spawn(process.execPath, ['tools/reqboard/server.mjs'], {
  cwd: path.resolve(import.meta.dirname, '..', '..'),
  env: { ...process.env, REQBOARD_ROOT: ROOT, REQBOARD_PORT: String(PORT), REQBOARD_NO_OPEN: '1' },
  stdio: 'ignore',
});

async function waitReady() {
  for (let i = 0; i < 50; i++) {
    try {
      await fetch(`${BASE}/api/overview`);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  throw new Error('server did not start');
}

async function post(p, body) {
  const res = await fetch(BASE + p, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json().catch(() => null) };
}

test.before(async () => {
  await waitReady();
});

test.after(() => {
  child.kill();
});

test('GET / 返回页面，/api/overview 返回解析结果', async () => {
  const page = await fetch(`${BASE}/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type') || '', /text\/html/);
  const html = await page.text();
  assert.match(html, /需求看板/);

  const ov = await fetch(`${BASE}/api/overview`);
  assert.equal(ov.status, 200);
  const j = await ov.json();
  assert.equal(j.backlog.totalRows, 2);
  assert.equal(j.backlog.poolRows, 2);
  assert.equal(j.suggestions.nextVersion, 'v0.4');
});

test('POST /api/backlog/update：expect 不匹配返回 400 且不落盘', async () => {
  const before = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8');
  const r = await post('/api/backlog/update', {
    file: BACKLOG,
    line: 7,
    expect: '| 错误预期 |',
    cells: ['x', 'y', 'z', '—', '未分配版本'],
  });
  assert.equal(r.status, 400);
  assert.match(r.json.error, /不一致/);
  assert.equal(fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8'), before);
});

test('POST /api/schedule（mode=new）：创建版本 + README 索引行 + 需求池补记', async () => {
  const r = await post('/api/schedule', {
    mode: 'new',
    version: 'v1.0',
    milestone: 'M9',
    positioning: '端到端测试版本',
    rows: [
      {
        file: BACKLOG,
        line: 7,
        expect: '| 括号补全 | 顺手 | 低 | — | 未分配版本 |',
        cells: ['括号补全', '顺手', '低', '—', '未分配版本'],
        section: 'A. 编辑器',
        name: '括号补全',
        value: '顺手',
        cost: '低',
      },
    ],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);

  // 版本文档已创建
  const doc = fs.readFileSync(path.join(ROOT, 'docs/releases/v1.0/需求文档.md'), 'utf8');
  assert.match(doc, /# v1\.0 需求文档/);
  assert.match(doc, /> 状态：规划中/);
  assert.match(doc, /来自需求池「A\. 编辑器」：括号补全/);

  // README 索引追加一行
  const readme = fs.readFileSync(path.join(ROOT, README), 'utf8');
  assert.match(readme, /\| v1\.0 \| ⚪ 规划中/);

  // 需求池行补记，且保持 CRLF
  const backlog = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8');
  assert.match(backlog, /分配 \[v1\.0\]\(releases\/v1\.0\/需求文档\.md\)（需求看板排期） \|\r\n/);

  // overview 反映新版本
  const j = await (await fetch(`${BASE}/api/overview`)).json();
  assert.ok(j.suggestions.knownVersions.includes('v1.0'));
  assert.equal(j.backlog.poolRows, 1);
});

test('POST /api/schedule（mode=existing）：追加 §3；已冻结版本拒绝', async () => {
  const r = await post('/api/schedule', {
    mode: 'existing',
    version: 'v0.2',
    rows: [
      {
        file: BACKLOG,
        line: 8,
        expect: '| 行号开关 | 排版 | 低 | — | 未分配版本 |',
        cells: ['行号开关', '排版', '低', '—', '未分配版本'],
        section: 'A. 编辑器',
        name: '行号开关',
        value: '排版',
        cost: '低',
      },
    ],
  });
  assert.equal(r.status, 200);
  const doc = fs.readFileSync(path.join(ROOT, 'docs/releases/v0.2/需求文档.md'), 'utf8');
  assert.match(doc, /- \[看板排期 \d{4}-\d{2}-\d{2}\] 来自需求池「A\. 编辑器」：行号开关/);
  const backlog = fs.readFileSync(path.join(ROOT, BACKLOG), 'utf8');
  assert.match(backlog, /分配 \[v0\.2\]\(releases\/v0\.2\/需求文档\.md\)/);

  // 冻结版本拒绝追加
  const frozen = await post('/api/schedule', {
    mode: 'existing',
    version: 'v0.3',
    rows: [
      { file: BACKLOG, line: 8, expect: '| x |', cells: ['x'], section: 'A. 编辑器', name: 'x', value: '', cost: '' },
    ],
  });
  assert.equal(frozen.status, 400);
  assert.match(frozen.json.error, /冻结/);
});
