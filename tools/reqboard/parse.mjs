// 需求看板：解析 docs/ 需求池与版本文档 + 受控写回工具。
// 纯逻辑模块：server.mjs 与 tools/tests/test_reqboard.mjs 共用。

import fs from 'node:fs';
import path from 'node:path';

export const REPO_ROOT = process.env.REQBOARD_ROOT
  ? path.resolve(process.env.REQBOARD_ROOT)
  : path.resolve(import.meta.dirname, '..', '..');

// ---------- 文档行级读写（保留每行原有 EOL） ----------

export function readDocLines(relPath) {
  const abs = path.join(REPO_ROOT, relPath);
  const text = fs.readFileSync(abs, 'utf8');
  const rawLines = text.split(/(?<=\n)/);
  if (rawLines.length > 0 && rawLines[rawLines.length - 1] === '') {
    rawLines.pop();
  }
  let crlf = 0;
  let lf = 0;
  for (const l of rawLines) {
    if (l.endsWith('\r\n')) crlf++;
    else if (l.endsWith('\n')) lf++;
  }
  return { abs, rawLines, eol: crlf >= lf ? '\r\n' : '\n' };
}

export function lineContent(rawLine) {
  return rawLine.replace(/\r?\n$/, '');
}

function lineTerminator(rawLine) {
  const m = rawLine.match(/\r?\n$/);
  return m ? m[0] : '';
}

// edits: [{type:'replace'|'delete', line(1-based), expect, content?} | {type:'insertAfter', line(1-based), content}]
// 逐条校验 expect（乐观锁），任何一条不匹配即整体失败，不写盘。
export function applyEdits(relPath, edits) {
  const doc = readDocLines(relPath);
  const raw = [...doc.rawLines];
  const check = (line, expect) => {
    if (!Number.isInteger(line) || line < 1 || line > raw.length) {
      throw new Error(`行号越界：${line}`);
    }
    if (expect !== undefined && lineContent(raw[line - 1]) !== expect) {
      throw new Error(`第 ${line} 行内容与预期不一致（文件可能已被其他方式修改），请刷新页面后重试`);
    }
  };
  for (const e of edits) {
    if (e.type === 'replace') {
      check(e.line, e.expect);
      raw[e.line - 1] = e.content + lineTerminator(raw[e.line - 1]);
    } else if (e.type === 'delete') {
      check(e.line, e.expect);
      raw.splice(e.line - 1, 1);
    } else if (e.type === 'insertAfter') {
      check(e.line, undefined);
      raw.splice(e.line, 0, e.content + doc.eol);
    } else {
      throw new Error(`未知编辑类型：${e.type}`);
    }
  }
  const out = raw.join('');
  const tmp = doc.abs + '.reqboard-tmp';
  fs.writeFileSync(tmp, out, 'utf8');
  fs.renameSync(tmp, doc.abs);
  return { ok: true };
}

export function writeNewDoc(relPath, content) {
  const abs = path.join(REPO_ROOT, relPath);
  if (fs.existsSync(abs)) {
    throw new Error(`文件已存在：${relPath}`);
  }
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  const tmp = abs + '.reqboard-tmp';
  fs.writeFileSync(tmp, content, 'utf8');
  fs.renameSync(tmp, abs);
}

// ---------- markdown 表格解析 ----------

export function unescapeCell(s) {
  return s.replace(/\\\|/g, '|').trim();
}

export function escapeCell(s) {
  return String(s ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ').trim();
}

export function splitRowCells(line) {
  let t = line.trim();
  if (t.startsWith('|')) t = t.slice(1);
  if (t.endsWith('|') && !t.endsWith('\\|')) t = t.slice(0, -1);
  const parts = [];
  let cur = '';
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (ch === '\\' && t[i + 1] === '|') {
      cur += '\\|';
      i++;
    } else if (ch === '|') {
      parts.push(unescapeCell(cur));
      cur = '';
    } else {
      cur += ch;
    }
  }
  parts.push(unescapeCell(cur));
  return parts;
}

const SEP_RE = /^\|?\s*:?-{2,}/;

export function isSeparatorLine(line) {
  const t = line.trim();
  return t.startsWith('|') && SEP_RE.test(t) && /^[\s|:-]+$/.test(t);
}

// 返回 [{headerLine, sepLine, headers, rows:[{line, cells}]}]，行号 1-based。
export function parseMarkdownTables(lines) {
  const tables = [];
  let i = 0;
  const n = lines.length;
  while (i < n) {
    const cur = lines[i].trim();
    if (cur.startsWith('|') && i + 1 < n && isSeparatorLine(lines[i + 1])) {
      const headerLine = i + 1;
      const sepLine = i + 2;
      const headers = splitRowCells(lines[i]);
      const rows = [];
      let j = i + 2;
      while (j < n && lines[j].trim().startsWith('|') && !isSeparatorLine(lines[j])) {
        rows.push({ line: j + 1, cells: splitRowCells(lines[j]) });
        j++;
      }
      tables.push({ headerLine, sepLine, headers, rows });
      i = j;
    } else {
      i++;
    }
  }
  return tables;
}

export function nearestHeading(lines, tableStartLine0) {
  for (let i = tableStartLine0 - 1; i >= 0; i--) {
    const t = lines[i].trim();
    if (/^#{1,6}\s+/.test(t)) {
      return { line: i + 1, text: t.replace(/^#{1,6}\s+/, '').trim() };
    }
  }
  return null;
}

// ---------- 需求池 ----------

const VERSION_RE = /v(\d{1,2})\.(\d{1,3})/g;

function decodeAnchorVersions(text) {
  const out = [];
  for (const m of text.matchAll(/#v(\d{1,4})-/g)) {
    const digits = m[1];
    let major;
    let minor;
    if (digits.startsWith('0')) {
      major = 0;
      minor = digits.slice(1);
    } else {
      major = digits[0];
      minor = digits.slice(1);
    }
    if (minor !== '') {
      out.push(`v${major}.${minor}`);
    }
  }
  return out;
}

// 版本归属只看最后一列（MVP 建议 / 状态 / 分配列）——依赖列里出现的 vX.Y 不是排期记录。
export function classifyRow(cells) {
  const note = cells.length > 0 ? cells[cells.length - 1] : '';
  if (/已?关闭|砍掉|已放弃|不成立|已作废|已废止/.test(note)) {
    return { status: 'closed', versions: [] };
  }
  if (/已在 MVP/.test(note)) {
    return { status: 'mvp', versions: [] };
  }
  const versions = new Set();
  for (const m of note.matchAll(VERSION_RE)) {
    versions.add(`v${m[1]}.${m[2]}`);
  }
  for (const v of decodeAnchorVersions(note)) {
    versions.add(v);
  }
  if (versions.size > 0) {
    return { status: 'assigned', versions: [...versions] };
  }
  if (/未分配|不排期|此处不做排期/.test(note)) {
    return { status: 'pool', versions: [] };
  }
  if (/已分配|分配至|分配 \[|立项|承接|归入/.test(note)) {
    return { status: 'assigned', versions: [] };
  }
  return { status: 'pool', versions: [] };
}

// 在版本需求文档里找「## 3. 需求清单」小节的内容末尾行号（1-based，insertAfter 用）。
export function findSection3InsertLine(relPath) {
  const doc = readDocLines(relPath);
  const lines = doc.rawLines.map(lineContent);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^##\s*3[\.\s、]/.test(lines[i])) {
      start = i;
      break;
    }
  }
  if (start < 0) {
    throw new Error('需求文档里找不到「## 3. 需求清单」小节，无法追加条目');
  }
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^#{1,2}\s/.test(lines[i])) {
      end = i;
      break;
    }
  }
  let insertAt = start;
  for (let i = end - 1; i > start; i--) {
    if (lines[i].trim() !== '') {
      insertAt = i;
      break;
    }
  }
  return insertAt + 1;
}

export function parseBacklog(relPath) {
  const doc = readDocLines(relPath);
  const lines = doc.rawLines.map(lineContent);
  const tables = parseMarkdownTables(lines);
  const sections = [];
  let current = null;
  for (const t of tables) {
    const h = nearestHeading(lines, t.headerLine - 1);
    const title = h ? h.text : '（无标题）';
    if (!current || current.title !== title) {
      current = { title, tables: [] };
      sections.push(current);
    }
    current.tables.push({
      headerLine: t.headerLine,
      sepLine: t.sepLine,
      headers: t.headers,
      rows: t.rows.map((r) => {
        const cls = classifyRow(r.cells);
        return {
          line: r.line,
          raw: lines[r.line - 1],
          cells: r.cells,
          name: r.cells[0] ?? '',
          status: cls.status,
          versions: cls.versions,
        };
      }),
    });
  }
  return { file: relPath, sections };
}

// ---------- 版本数据 ----------

export function classifyVersionStatus(statusText) {
  const t = statusText ?? '';
  if (/🔒|冻结/.test(t)) return 'frozen';
  if (/已发布|✅/.test(t)) return 'released';
  if (/关闭/.test(t)) return 'closed';
  if (/⚪|规划中/.test(t)) return 'planning';
  if (/🟡|开发中|进行中|▶|继续|实现中|本地实现完成|实现完成/.test(t)) return 'progress';
  return 'progress';
}

// 解析 docs/releases/README.md §4 版本索引表（headers[0] === '版本'）。
export function parseVersionIndex(relPath) {
  const doc = readDocLines(relPath);
  const lines = doc.rawLines.map(lineContent);
  const tables = parseMarkdownTables(lines);
  const out = [];
  for (const t of tables) {
    if ((t.headers[0] ?? '').trim() !== '版本') continue;
    for (const r of t.rows) {
      if (r.cells.length < 4) continue;
      const version = r.cells[0].trim();
      if (!/^v\d+\.\d+$/.test(version)) continue;
      const statusText = r.cells[1];
      const linkCell = r.cells[4] ?? r.cells[3] ?? '';
      let docPath = null;
      let archived = false;
      const m = linkCell.match(/\(([^)]+)\)/);
      if (m) {
        const href = m[1];
        if (/^v[\d.]+\/需求文档\.md$/.test(href)) {
          docPath = `docs/releases/${href}`;
        } else if (href.includes('历史版本归档.md#')) {
          docPath = `docs/releases/${href.split('#')[0]}`;
          archived = true;
        } else if (href.endsWith('.md')) {
          docPath = `docs/releases/${href}`;
        }
      }
      out.push({
        version,
        line: r.line,
        statusText,
        statusKey: classifyVersionStatus(statusText),
        milestone: r.cells[2],
        desc: r.cells[3],
        docPath,
        archived,
      });
    }
  }
  return out;
}

// 解析 docs/releases/历史版本速查.md 的表（headers[0] === '版本'）。
export function parseQuickIndex(relPath) {
  const doc = readDocLines(relPath);
  const lines = doc.rawLines.map(lineContent);
  const tables = parseMarkdownTables(lines);
  const out = [];
  for (const t of tables) {
    if ((t.headers[0] ?? '').trim() !== '版本') continue;
    for (const r of t.rows) {
      const version = (r.cells[0] ?? '').trim();
      if (!/^v\d+\.\d+$/.test(version)) continue;
      out.push({
        version,
        milestone: r.cells[1] ?? '',
        desc: r.cells[2] ?? '',
        summary: r.cells[3] ?? '',
      });
    }
  }
  return out;
}

// 解析 docs/releases/历史版本归档.md 的 `## vX.Y …` 标题，返回去重版本号列表。
export function parseArchivedVersions(relPath) {
  const doc = readDocLines(relPath);
  const lines = doc.rawLines.map(lineContent);
  const set = new Set();
  for (const l of lines) {
    const m = l.match(/^##\s+(v\d+\.\d+)\s/);
    if (m) set.add(m[1]);
  }
  return [...set].sort(compareVersions);
}

export function compareVersions(a, b) {
  const pa = a.replace(/^v/, '').split('.').map(Number);
  const pb = b.replace(/^v/, '').split('.').map(Number);
  if (pa[0] !== pb[0]) return pa[0] - pb[0];
  return pa[1] - pb[1];
}

// 活跃版本目录（docs/releases/vX.Y/）下读取需求文档状态。
export function scanVersionDirs(releasesDirRel) {
  const abs = path.join(REPO_ROOT, releasesDirRel);
  const out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(abs, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (!/^v\d+\.\d+$/.test(e.name)) continue;
    const docRel = `${releasesDirRel}/${e.name}/需求文档.md`;
    const docAbs = path.join(REPO_ROOT, docRel);
    const info = { version: e.name, docPath: null, status: null, statusKey: null, title: null };
    if (fs.existsSync(docAbs)) {
      info.docPath = docRel;
      const text = fs.readFileSync(docAbs, 'utf8');
      const title = text.match(/^#\s+(.+)$/m);
      info.title = title ? title[1].trim() : null;
      // 兼容 `> 状态：` 与 `> **状态**：`（粗体星号）两种写法
      const st = text.match(/^>\s*\*{0,2}\s*状态\s*\*{0,2}\s*[：:]\s*(.+)$/m);
      if (st) {
        info.status = st[1].trim();
        info.statusKey = classifyVersionStatus(info.status);
      }
    }
    out.push(info);
  }
  return out.sort((a, b) => compareVersions(a.version, b.version));
}

// 实施总清单里的执行队列：`- [ ] [vX.Y](…)` 勾选项。
export function parseQueue(relPath) {
  const doc = readDocLines(relPath);
  const lines = doc.rawLines.map(lineContent);
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^-\s\[ \]\s*\[(v\d+\.\d+)\][^）]*（(.*)$/);
    if (m) {
      out.push({ version: m[1], text: lines[i].replace(/^-\s\[ \]\s*/, '').trim(), line: i + 1 });
      continue;
    }
    const m2 = lines[i].match(/^-\s\[ \]\s*\[(v\d+\.\d+)\]/);
    if (m2) {
      out.push({ version: m2[1], text: lines[i].replace(/^-\s\[ \]\s*/, '').trim(), line: i + 1 });
    }
  }
  return out;
}

export function parseChangelog(relPath) {
  const abs = path.join(REPO_ROOT, relPath);
  const data = JSON.parse(fs.readFileSync(abs, 'utf8'));
  const entries = Array.isArray(data.entries) ? data.entries : [];
  return entries.map((e) => ({
    version: e.version,
    date: e.date,
    status: e.status,
    title: e.title ?? '',
  }));
}

// ---------- 版本号建议 ----------

export function suggestNextVersion(knownVersions) {
  let max = null;
  for (const v of knownVersions) {
    const m = v.match(/^v(\d+)\.(\d+)$/);
    if (!m) continue;
    const cur = [Number(m[1]), Number(m[2])];
    if (!max || cur[0] > max[0] || (cur[0] === max[0] && cur[1] > max[1])) {
      max = cur;
    }
  }
  if (!max) return 'v1.0';
  return `v${max[0]}.${max[1] + 1}`;
}

// ---------- 新版本脚手架 ----------

export function buildVersionDoc({ version, milestone, positioning, completion, items, notDoing, date }) {
  const itemLines = (items ?? []).map((it) =>
    `- 来自需求池「${it.section}」：${it.name}（价值 ${it.value || '—'} / 成本 ${it.cost || '—'}）；验收点待补充`
  );
  return [
    `# ${version} 需求文档`,
    '',
    '> 状态：规划中',
    `> 对应里程碑：${milestone || '（待定）'}（${date} 需求看板立项）`,
    '',
    '## 1. 版本定位',
    positioning || '（待补充）',
    '',
    '## 2. 完成判定',
    completion || '（待补充：一句话，可验收，写完能回答"这个版本做完没有"）',
    '',
    '## 3. 需求清单',
    '（从需求池分配过来的条目，写明来源章节与验收点）',
    ...(itemLines.length > 0 ? itemLines : ['（待补充）']),
    '',
    '## 4. 明确不做',
    notDoing || '（待补充：本版本排除什么、为什么）',
    '',
    '## 5. 技术约束与依赖',
    '- 环境事实：API 24 / ArkTS / Stage 模型 / 包名 `com.jxg.huaweiobsidian`',
    '- 结论只准链接，不准复制：鸿蒙行为结论 → `docs/harmonyos/api_notes.md`；已定决策 → `docs/open_questions.md`；架构与里程碑 → `docs/mvp_design.md`',
    '- 颜色 / 圆角 / 间距 / 字号只引用 token（AGENTS.md 硬约束 17）',
    '- 版本号是内部迭代编号，不与 `app.json5` 的 versionName 对应（README R1）',
    '',
    '## 6. 验收记录',
    '（发布后填：真机实测结果、遗留问题、下一步）',
    '',
  ].join('\n');
}

export function buildReadmeIndexRow({ version, milestone, positioning, date }) {
  const safe = (s) => escapeCell(s);
  return `| ${version} | ⚪ 规划中（${date} 需求看板立项） | ${safe(milestone || '—')} | ${safe(positioning || '待补充')} | [需求文档](${version}/需求文档.md) |`;
}

// 把排期注记追加到需求池某行的最后一个单元格。
export function appendAssignNote(cells, { version, date }) {
  const next = [...cells];
  const note = `${date} 分配 [${version}](releases/${version}/需求文档.md)（需求看板排期）`;
  const last = next.length - 1;
  if (last < 0) {
    next.push(note);
  } else {
    next[last] = next[last] ? `${next[last]}；${note}` : note;
  }
  return next;
}

export function buildRowLine(cells) {
  return `| ${cells.map(escapeCell).join(' | ')} |`;
}
