/**
 * 滚动容器边界反馈防线（2026-11-19，v1.84 / v1.86 / AGC UX 2.1.5.3.3）。
 *
 * 背景：ArkUI `Scroll` / `Grid` / `WaterFlow` 的 `edgeEffect` 默认值是
 * `EdgeEffect.None`（SDK common.d.ts JSDoc）——滚动到边界无任何反馈动效；
 * `List` 默认 `EdgeEffect.Spring` 有回弹。v1.84 已给全部 `Scroll` 显式
 * `.edgeEffect(EdgeEffect.Spring)`（29 处 + EditorMismatchDialog 既有 1 处）。
 *
 * 规则：新增或改写的 `Scroll` / `Grid` / `WaterFlow` 组件声明必须在其属性链
 * 显式设置 `.edgeEffect(...)`（无豁免清单——需要禁用回弹的场景极少，届时在此
 * 登记豁免并写明理由）。`List` 默认 Spring，不要求显式声明。
 *
 * v1.86：ArkWeb `Web` 组件 `overScrollMode` 默认 `OverScrollMode.NEVER`
 * （SDK web.d.ts，API 11+，api_notes AJ1）——Web 内容滚动到边界同样无反馈。
 * 用户可见且自滚动的 `Web(` 声明必须显式 `.overScrollMode(...)`；
 * 豁免清单：GitBridgeView（1×1 隐形 git 引擎，无可见滚动）。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve, dirname, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const etsRoot = join(repoRoot, 'entry/src/main/ets');

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      out.push(...walk(full));
    } else if (name.endsWith('.ets')) {
      out.push(full);
    }
  }
  return out;
}

/**
 * 从 openIndex（指向 `(` 或 `{`）返回与之平衡的闭合符索引；跳过字符串与注释。
 * closeChar 与 openChar 成对使用（() 或 {}）。
 */
function findBalanced(source, openIndex, openChar, closeChar) {
  let depth = 0;
  let i = openIndex;
  let quote = null;
  while (i < source.length) {
    const ch = source[i];
    if (quote !== null) {
      if (ch === '\\') {
        i += 2;
        continue;
      }
      if (ch === quote) quote = null;
      i++;
      continue;
    }
    if (ch === '\'' || ch === '"' || ch === '`') {
      quote = ch;
      i++;
      continue;
    }
    if (ch === '/' && source[i + 1] === '/') {
      const nl = source.indexOf('\n', i);
      i = nl === -1 ? source.length : nl + 1;
      continue;
    }
    if (ch === '/' && source[i + 1] === '*') {
      const end = source.indexOf('*/', i + 2);
      i = end === -1 ? source.length : end + 2;
      continue;
    }
    if (ch === openChar) {
      depth++;
    } else if (ch === closeChar) {
      depth--;
      if (depth === 0) return i;
    }
    i++;
  }
  return -1;
}

/** 跳过空白与注释，返回下一处非空白字符索引 */
function skipBlank(source, i) {
  while (i < source.length) {
    const ch = source[i];
    if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') {
      i++;
    } else if (ch === '/' && source[i + 1] === '/') {
      const nl = source.indexOf('\n', i);
      i = nl === -1 ? source.length : nl + 1;
    } else if (ch === '/' && source[i + 1] === '*') {
      const end = source.indexOf('*/', i + 2);
      i = end === -1 ? source.length : end + 2;
    } else {
      return i;
    }
  }
  return -1;
}

/**
 * 找出全部 Scroll/Grid/WaterFlow 组件声明及其属性链。
 * 返回 [{ line, attrs: string[] }]；attrs 为组件块 `}` 之后链式属性名列表。
 * 词边界排除 updateWorkspaceScroll / onWorkspaceScroll 等方法名与 `new Scroll(`。
 */
export function findScrollComponents(source) {
  const results = [];
  const re = /\b(Scroll|Grid|WaterFlow)\(/g;
  let m;
  while ((m = re.exec(source)) !== null) {
    const name = m[1];
    const before = source.slice(Math.max(0, m.index - 20), m.index);
    if (/function\s+$/.test(before) || /new\s+$/.test(before)) continue;
    const line = source.slice(0, m.index).split('\n').length;
    const argsOpen = m.index + m[0].length - 1;
    const argsClose = findBalanced(source, argsOpen, '(', ')');
    if (argsClose === -1) continue;
    // Scroll 声明必带内容块 `{ ... }`；Grid/WaterFlow 亦然
    const braceOpen = skipBlank(source, argsClose + 1);
    if (braceOpen === -1 || source[braceOpen] !== '{') continue;
    const braceClose = findBalanced(source, braceOpen, '{', '}');
    if (braceClose === -1) continue;
    // 解析块后链式属性
    const attrs = [];
    let i = skipBlank(source, braceClose + 1);
    while (i !== -1 && source[i] === '.') {
      const nameMatch = /^[A-Za-z_$][\w$]*/.exec(source.slice(i + 1));
      if (!nameMatch) break;
      const attrName = nameMatch[0];
      const attrParen = skipBlank(source, i + 1 + nameMatch[0].length);
      if (attrParen === -1 || source[attrParen] !== '(') break;
      const attrClose = findBalanced(source, attrParen, '(', ')');
      if (attrClose === -1) break;
      attrs.push(attrName);
      i = skipBlank(source, attrClose + 1);
    }
    results.push({ name, line, attrs });
  }
  return results;
}

const files = walk(etsRoot);

test('every Scroll/Grid/WaterFlow component declares an explicit edgeEffect (AGC UX 2.1.5.3.3)', () => {
  const violations = [];
  for (const file of files) {
    const rel = relative(etsRoot, file).split(sep).join('/');
    const source = readFileSync(file, 'utf8');
    for (const comp of findScrollComponents(source)) {
      if (!comp.attrs.includes('edgeEffect')) {
        violations.push(`${rel}:${comp.line} -> ${comp.name} 属性链 [${comp.attrs.join(', ')}] 缺 edgeEffect`);
      }
    }
  }
  assert.deepEqual(
    violations, [],
    `Scroll/Grid/WaterFlow 的 edgeEffect 默认是 EdgeEffect.None（无边界反馈），组件声明必须显式设置 .edgeEffect(...)（v1.84）：\n${violations.join('\n')}`
  );
});

test('v1.84 legacy Scroll sites keep spring edge effect and nested-scroll wiring intact', () => {
  const gitSync = readFileSync(join(etsRoot, 'components/GitSyncDialog.ets'), 'utf8');
  assert.ok(/\.nestedScroll\(\{\s*\n?\s*scrollForward: NestedScrollMode\.SELF_FIRST/.test(gitSync),
    'GitSyncDialog diff 查看器 nestedScroll(SELF_FIRST) 配置应保持（v1.78 键盘避让配套）');
  const scrolled = findScrollComponents(gitSync);
  assert.equal(scrolled.length, 4, 'GitSyncDialog 应保持 4 处 Scroll 声明');
  for (const comp of scrolled) {
    assert.ok(comp.attrs.includes('edgeEffect'),
      `GitSyncDialog:${comp.line} Scroll 应含 edgeEffect`);
    assert.ok(comp.attrs.includes('nestedScroll') || comp.line > 1500,
      `GitSyncDialog:${comp.line} 嵌套滚动配置不应丢失`);
  }
});

/**
 * 找出全部 Web 组件声明及其属性链（v1.86 / api_notes AJ1）。
 * Web 无内容块：`Web({...})` 后直接跟链式属性。
 * 词边界排除 `new Web(`；嵌套滚动场景按 SDK 建议可豁免（登记理由）。
 */
export function findWebComponents(source) {
  const results = [];
  const re = /\bWeb\(/g;
  let m;
  while ((m = re.exec(source)) !== null) {
    const before = source.slice(Math.max(0, m.index - 20), m.index);
    if (/function\s+$/.test(before) || /new\s+$/.test(before)) continue;
    const line = source.slice(0, m.index).split('\n').length;
    const argsOpen = m.index + m[0].length - 1;
    const argsClose = findBalanced(source, argsOpen, '(', ')');
    if (argsClose === -1) continue;
    const attrs = [];
    let i = skipBlank(source, argsClose + 1);
    while (i !== -1 && source[i] === '.') {
      const nameMatch = /^[A-Za-z_$][\w$]*/.exec(source.slice(i + 1));
      if (!nameMatch) break;
      const attrParen = skipBlank(source, i + 1 + nameMatch[0].length);
      if (attrParen === -1 || source[attrParen] !== '(') break;
      const attrClose = findBalanced(source, attrParen, '(', ')');
      if (attrClose === -1) break;
      attrs.push(nameMatch[0]);
      i = skipBlank(source, attrClose + 1);
    }
    results.push({ line, attrs });
  }
  return results;
}

/** Web overScrollMode 豁免清单（相对 etsRoot 的 POSIX 路径 → 理由） */
const WEB_OVERSCROLL_EXEMPT = {
  'git/GitBridgeView.ets': '1×1 隐形 git 引擎（v1.86 86.1）：无用户可见滚动，不加属性保持引擎纯净',
};

test('every user-visible Web component declares an explicit overScrollMode (AGC UX 2.1.5.3.3, v1.86)', () => {
  const violations = [];
  let webCount = 0;
  for (const file of files) {
    const rel = relative(etsRoot, file).split(sep).join('/');
    const source = readFileSync(file, 'utf8');
    for (const comp of findWebComponents(source)) {
      webCount++;
      if (WEB_OVERSCROLL_EXEMPT[rel]) continue;
      if (!comp.attrs.includes('overScrollMode')) {
        violations.push(`${rel}:${comp.line} -> Web 属性链 [${comp.attrs.join(', ')}] 缺 overScrollMode`);
      }
    }
  }
  assert.deepEqual(
    violations, [],
    `Web 的 overScrollMode 默认是 OverScrollMode.NEVER（无过滚动反馈），用户可见的 Web 组件声明必须显式设置 .overScrollMode(...)（v1.86 / api_notes AJ1）：\n${violations.join('\n')}`
  );
  assert.ok(webCount >= 7, `应识别到至少 7 处 Web 声明（当前 ${webCount}），解析器失效时防线会静默变绿，必须显式计数`);
});
