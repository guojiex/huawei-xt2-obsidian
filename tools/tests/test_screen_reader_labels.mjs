/**
 * v1.10 基础无障碍 —— 读屏名称回归。
 *
 * 为什么是源码扫描而不是设备断言：本地没有稳定的读屏服务夹具，
 * 「控件有没有名字」这件事在源码层是确定且可回归的（ArkUI 读屏直接取
 * accessibilityText / 组件文本），设备验收另记。
 *
 * 规则（与 v1.10 §2 一致）：
 *  1. **纯图标按钮**必须有 accessibilityText —— 没有可见文字，读屏否则无内容可读；
 *  2. **图标 + 文字**的可点行至少要能被读屏读出状态，允许用 accessibilityText 补状态；
 *  3. accessibilityText 不能是空串或纯占位（'图标' / 'button' 之类无意义值）。
 *
 * 扫描方式：找「Row 块内只有 Icon（无 Text / Span / SymbolGlyph）」且带 onClick 的容器，
 * 再看它的属性链里有没有 accessibilityText。纯启发式，但对本仓库的写法足够确定。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve, dirname, relative } from 'node:path';
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

const files = walk(etsRoot);

/** 找出「块内只有图标」的可点容器 */
export function findIconOnlyButtons(source) {
  const lines = source.split('\n');
  const found = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)(Row|Stack|Column)\((?:\s*\{[^}]*\})?\s*\{\s*$/);
    if (!m) continue;
    const indent = m[1].length;
    // 块体：直到缩进相同的闭合 }
    let j = i + 1;
    let body = [];
    while (j < lines.length) {
      const line = lines[j];
      if (line.trim() === '}' && (line.match(/^\s*/) ?? [''])[0].length === indent) break;
      body.push(line);
      j++;
    }
    if (j >= lines.length) continue;
    const bodyText = body.join('\n');
    const hasIcon = /(^|[^\w])Icon\(/.test(bodyText);
    const hasText = /(^|[^\w])(Text|Span|SymbolGlyph|Image)\(/.test(bodyText);
    if (!hasIcon || hasText) continue;
    // 属性链：闭合后的连续更深缩进行
    let k = j + 1;
    let chain = [];
    while (k < lines.length) {
      const line = lines[k];
      if (line.trim().length === 0) { chain.push(line); k++; continue; }
      const cur = (line.match(/^\s*/) ?? [''])[0].length;
      if (cur <= indent) break;
      chain.push(line);
      k++;
    }
    const chainText = chain.join('\n');
    // 嵌套的子容器（如 Stack 里的 Row）自己会被单独扫到，这里只看最外层链
    if (!/\.onClick\(/.test(chainText)) continue;
    found.push({
      file: '',
      line: i + 1,
      chain: chainText,
      labelled: /\.accessibilityText\(/.test(chainText)
    });
  }
  return found;
}

/** 抽 accessibilityText 的字面量（用于判断是不是占位文案） */
function accessibilityLiterals(chain) {
  const out = [];
  const re = /\.accessibilityText\(\s*('[^']*')/g;
  let m;
  while ((m = re.exec(chain)) !== null) {
    out.push(m[1].slice(1, -1));
  }
  return out;
}

const PLACEHOLDER = new Set(['图标', '按钮', 'button', 'icon', '', ' ']);

test('every icon-only clickable control has an accessibility label', () => {
  const missing = [];
  for (const file of files) {
    const source = readFileSync(file, 'utf8');
    for (const hit of findIconOnlyButtons(source)) {
      if (!hit.labelled) {
        missing.push(`${relative(repoRoot, file)}:${hit.line}`);
      }
    }
  }
  assert.deepEqual(missing, [], `这些纯图标按钮没有读屏名称：\n${missing.join('\n')}`);
});

test('accessibility labels are meaningful, not placeholders', () => {
  const bad = [];
  for (const file of files) {
    const source = readFileSync(file, 'utf8');
    for (const hit of findIconOnlyButtons(source)) {
      for (const text of accessibilityLiterals(hit.chain)) {
        if (PLACEHOLDER.has(text.trim())) {
          bad.push(`${relative(repoRoot, file)}:${hit.line} -> "${text}"`);
        }
      }
    }
  }
  assert.deepEqual(bad, [], `读屏名称无意义：\n${bad.join('\n')}`);
});

test('the icon-only controls this version labelled are still wired', () => {
  const expected = [
    ['components/VaultSidebar.ets', '搜索笔记'],
    ['components/VaultSidebar.ets', '新建笔记'],
    ['components/VaultSidebar.ets', '切换知识库，当前 '],
    ['components/VaultSidebar.ets', '章节：'], // 章节折叠：'展开'/'折叠' + '章节：'
    ['components/FileTreeView.ets', '下新建'],
    ['components/FileTreeView.ets', '在参考栏打开'],
    ['pages/Index.ets', 'Git 同步'],
    // v1.44 统一双栏更多菜单入口：每栏「更多操作」按钮已整体移除，统一入口是顶栏「更多菜单」
    ['pages/Index.ets', '更多菜单'],
    ['pages/Index.ets', '插入图片'],
    ['components/AgentWorkspace.ets', '归档对话']
  ];
  for (const [relativePath, ...needles] of expected) {
    const source = readFileSync(join(etsRoot, relativePath), 'utf8');
    for (const needle of needles) {
      assert.ok(source.includes(needle), `${relativePath} 应包含读屏名称片段「${needle}」`);
    }
  }
});

test('state is announced, not just drawn: selected / expanded states reach the label', () => {
  const cases = [
    ['components/NoteDialogs.ets', '，已选中'],
    ['components/VaultSidebar.ets', '，当前知识库'],
    ['pages/Index.ets', '收起菜单'],
    ['pages/Index.ets', '展开菜单']
  ];
  for (const [relativePath, needle] of cases) {
    const source = readFileSync(join(etsRoot, relativePath), 'utf8');
    assert.ok(source.includes(needle), `${relativePath} 应把状态「${needle}」写进读屏文案`);
  }
});

test('accessibility APIs used here are declared for the compiled SDK level', () => {
  // 只断言本机 SDK 里确有这些属性声明（版本由 api_notes L-15 记录：since 12 / 10，低于 API 24）
  // SDK 根随宿主平台解析：Windows 为 DevEco 安装目录，macOS 为 DevEco-Studio.app 内
  const sdkCommon = process.platform === 'win32'
    ? 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/component/common.d.ts'
    : '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/component/common.d.ts';
  const common = readFileSync(sdkCommon, 'utf8');
  for (const api of ['accessibilityText(', 'accessibilityTextHint(', 'accessibilityDescription(', 'accessibilityLevel(', 'accessibilityGroup(']) {
    assert.ok(common.includes(`    ${api}`), `SDK 应声明 ${api}`);
  }
});
