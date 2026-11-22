// 需求看板本地服务：node tools/reqboard/server.mjs
// 浏览器打开 http://127.0.0.1:7812 ；REQBOARD_PORT 可改端口，REQBOARD_NO_OPEN=1 不自动开浏览器。

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { exec } from 'node:child_process';
import {
  REPO_ROOT,
  readDocLines,
  lineContent,
  applyEdits,
  writeNewDoc,
  parseBacklog,
  parseVersionIndex,
  parseQuickIndex,
  parseArchivedVersions,
  scanVersionDirs,
  parseQueue,
  parseChangelog,
  suggestNextVersion,
  buildVersionDoc,
  buildReadmeIndexRow,
  buildRowLine,
  appendAssignNote,
  compareVersions,
  classifyVersionStatus,
  findSection3InsertLine,
} from './parse.mjs';

const PORT = Number(process.env.REQBOARD_PORT || 7812);
const HOST = '127.0.0.1';
const BACKLOG_REL = 'docs/requirements_backlog.md';
const README_REL = 'docs/releases/README.md';
const QUICK_REL = 'docs/releases/历史版本速查.md';
const ARCHIVE_REL = 'docs/releases/历史版本归档.md';
const QUEUE_REL = 'docs/releases/实施总清单.md';
const CHANGELOG_REL = 'changelog.json';
const RELEASES_REL = 'docs/releases';

const READABLE_RE = /^(docs\/[\w\u4e00-\u9fff./ -]+\.md|changelog\.json|AGENTS\.md)$/;

function today() {
  const d = new Date();
  const p = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function knownVersions() {
  const set = new Set();
  for (const v of scanVersionDirs(RELEASES_REL)) set.add(v.version);
  for (const v of parseVersionIndex(README_REL)) set.add(v.version);
  for (const v of parseQuickIndex(QUICK_REL)) set.add(v.version);
  // 注意：parseArchivedVersions 返回的是版本号字符串数组，其余三个是对象数组。
  for (const v of parseArchivedVersions(ARCHIVE_REL)) set.add(v);
  return set;
}

function buildOverview() {
  const backlog = parseBacklog(BACKLOG_REL);
  const index = parseVersionIndex(README_REL);
  const quick = parseQuickIndex(QUICK_REL);
  const archived = parseArchivedVersions(ARCHIVE_REL);
  const dirs = scanVersionDirs(RELEASES_REL);
  const dirByVer = new Map(dirs.map((d) => [d.version, d]));
  const released = parseChangelog(CHANGELOG_REL);
  const queue = parseQueue(QUEUE_REL);

  const active = index.map((v) => {
    const d = dirByVer.get(v.version);
    return {
      ...v,
      dirDoc: d ? { docPath: d.docPath, status: d.status, statusKey: d.statusKey, title: d.title } : null,
    };
  });
  const known = knownVersions();
  let totalRows = 0;
  let poolRows = 0;
  for (const s of backlog.sections) {
    for (const t of s.tables) {
      for (const r of t.rows) {
        totalRows++;
        if (r.status === 'pool') poolRows++;
      }
    }
  }
  return {
    generatedAt: new Date().toISOString(),
    backlog: {
      file: BACKLOG_REL,
      totalRows,
      poolRows,
      sections: backlog.sections,
    },
    versions: {
      active,
      quick,
      archived,
      released,
    },
    queue,
    suggestions: {
      nextVersion: suggestNextVersion(known),
      knownVersions: [...known].sort(compareVersions),
    },
  };
}

function findReadmeIndexTableLastLine() {
  const doc = readDocLines(README_REL);
  const lines = doc.rawLines.map(lineContent);
  const rows = parseVersionIndex(README_REL);
  if (rows.length === 0) {
    throw new Error('README 版本索引表解析失败：没有可用行');
  }
  let max = 0;
  for (const r of rows) max = Math.max(max, r.line);
  return max;
}

function handleSchedule(body) {
  const date = today();
  const mode = body.mode === 'new' ? 'new' : 'existing';
  const version = String(body.version || '').trim();
  const rows = Array.isArray(body.rows) ? body.rows : [];
  if (rows.length === 0) throw new Error('没有选择任何需求条目');
  if (!/^v\d+\.\d+$/.test(version)) throw new Error(`版本号格式不正确：${version}（应为 vX.Y）`);
  for (const r of rows) {
    if (r.file !== BACKLOG_REL) throw new Error(`只允许排期需求池条目（收到 ${r.file}）`);
    if (!Number.isInteger(r.line) || !Array.isArray(r.cells)) {
      throw new Error('需求行数据不完整（缺少行号或单元格）');
    }
  }
  const results = [];
  if (mode === 'new') {
    const known = knownVersions();
    if (known.has(version)) throw new Error(`版本 ${version} 已存在（目录 / 索引 / 归档中有记录）`);
    const dirAbs = path.join(REPO_ROOT, RELEASES_REL, version);
    if (fs.existsSync(dirAbs)) throw new Error(`版本目录已存在：docs/releases/${version}`);
    const docRel = `${RELEASES_REL}/${version}/需求文档.md`;
    const content = buildVersionDoc({
      version,
      milestone: body.milestone,
      positioning: body.positioning,
      completion: body.completion,
      notDoing: body.notDoing,
      date,
      items: rows.map((r) => ({ section: r.section, name: r.name, value: r.value, cost: r.cost })),
    });
    writeNewDoc(docRel, content);
    results.push(`已创建 ${docRel}`);
    try {
      const lastLine = findReadmeIndexTableLastLine();
      applyEdits(README_REL, [
        {
          type: 'insertAfter',
          line: lastLine,
          content: buildReadmeIndexRow({ version, milestone: body.milestone, positioning: body.positioning, date }),
        },
      ]);
      results.push('已在 README 版本索引追加一行');
    } catch (e) {
      results.push(`⚠️ README 版本索引追加失败：${e.message}（可手动补一行，不影响已创建的版本文档）`);
    }
  } else {
    const docRel = `${RELEASES_REL}/${version}/需求文档.md`;
    const docAbs = path.join(REPO_ROOT, docRel);
    if (!fs.existsSync(docAbs)) {
      throw new Error(`版本 ${version} 没有进行中的需求文档目录（docs/releases/${version}/需求文档.md 不存在；已完结版本在历史版本归档里，规则 R7 冻结后不再改动）`);
    }
    const text = fs.readFileSync(docAbs, 'utf8');
    const st = text.match(/^>\s*\*{0,2}\s*状态\s*\*{0,2}\s*[：:]\s*(.+)$/m);
    const statusKey = st ? classifyVersionStatus(st[1].trim()) : 'progress';
    if (['released', 'frozen', 'closed'].includes(statusKey)) {
      throw new Error(`版本 ${version} 状态为「${st ? st[1].trim() : statusKey}」，已发布/冻结/关闭的版本不再追加需求（规则 R7）`);
    }
    const insertLine = findSection3InsertLine(docRel);
    const items = rows.map(
      (r) => `- [看板排期 ${date}] 来自需求池「${r.section}」：${r.name}（价值 ${r.value || '—'} / 成本 ${r.cost || '—'}）`
    );
    const edits = items.map((content, i) => ({ type: 'insertAfter', line: insertLine + i, content }));
    applyEdits(docRel, edits);
    results.push(`已在 ${docRel} §3 需求清单追加 ${items.length} 条`);
  }

  const edits = rows.map((r) => ({
    type: 'replace',
    line: r.line,
    expect: r.expect,
    content: buildRowLine(appendAssignNote(r.cells, { version, date })),
  }));
  try {
    applyEdits(BACKLOG_REL, edits);
    results.push(`已在需求池为 ${rows.length} 条需求补记「分配 ${version}」`);
  } catch (e) {
    results.push(`⚠️ 需求池补记失败：${e.message}`);
  }
  return { ok: true, results };
}

function sendJson(res, code, data) {
  const buf = Buffer.from(JSON.stringify(data));
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': buf.length });
  res.end(buf);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > 1024 * 1024) throw new Error('请求体过大');
    chunks.push(c);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${HOST}:${PORT}`);
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      const html = fs.readFileSync(path.join(import.meta.dirname, 'index.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': html.length });
      res.end(html);
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/overview') {
      sendJson(res, 200, buildOverview());
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/file') {
      const p = url.searchParams.get('path') || '';
      if (!READABLE_RE.test(p)) {
        sendJson(res, 400, { error: `不允许读取该路径：${p}` });
        return;
      }
      const abs = path.resolve(REPO_ROOT, p);
      if (!abs.startsWith(REPO_ROOT + path.sep) || !fs.existsSync(abs)) {
        sendJson(res, 404, { error: `文件不存在：${p}` });
        return;
      }
      const text = fs.readFileSync(abs, 'utf8');
      sendJson(res, 200, { path: p, text });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/backlog/update') {
      const b = await readBody(req);
      if (b.file !== BACKLOG_REL) throw new Error('只允许编辑需求池文件');
      if (!Number.isInteger(b.line) || typeof b.expect !== 'string' || !Array.isArray(b.cells)) {
        throw new Error('参数不完整');
      }
      applyEdits(BACKLOG_REL, [{ type: 'replace', line: b.line, expect: b.expect, content: buildRowLine(b.cells) }]);
      sendJson(res, 200, { ok: true });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/backlog/add') {
      const b = await readBody(req);
      if (b.file !== BACKLOG_REL) throw new Error('只允许编辑需求池文件');
      if (!Number.isInteger(b.anchorLine) || !Array.isArray(b.cells) || b.cells.length === 0) {
        throw new Error('参数不完整');
      }
      applyEdits(BACKLOG_REL, [{ type: 'insertAfter', line: b.anchorLine, content: buildRowLine(b.cells) }]);
      sendJson(res, 200, { ok: true });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/backlog/delete') {
      const b = await readBody(req);
      if (b.file !== BACKLOG_REL) throw new Error('只允许编辑需求池文件');
      if (!Number.isInteger(b.line) || typeof b.expect !== 'string') {
        throw new Error('参数不完整');
      }
      applyEdits(BACKLOG_REL, [{ type: 'delete', line: b.line, expect: b.expect }]);
      sendJson(res, 200, { ok: true });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/schedule') {
      const b = await readBody(req);
      sendJson(res, 200, handleSchedule(b));
      return;
    }
    sendJson(res, 404, { error: 'not found' });
  } catch (e) {
    sendJson(res, 400, { error: e.message, stack: process.env.REQBOARD_DEBUG ? e.stack : undefined });
  }
});

server.listen(PORT, HOST, () => {
  const url = `http://${HOST}:${PORT}`;
  console.log(`需求看板已启动：${url}`);
  console.log('数据真源：docs/requirements_backlog.md · docs/releases/ ；编辑会直接写回这些 markdown 文件。');
  console.log('Ctrl+C 停止。');
  if (!process.env.REQBOARD_NO_OPEN && process.platform === 'win32') {
    exec(`start "" "${url}"`, { shell: 'cmd.exe' });
  }
});
