/**
 * 全局 @Builder 按值实参冻结防线（2026-11-09，需求池 W 组）。
 *
 * 背景：`common/Icons.ets` 的 `Icon` 是全局 @Builder（多参按值传参）。官方
 * arkts-builder 限制与仓库实测（api_notes Z2 / L-7）一致：**按值实参在首帧固化、
 * 不随状态刷新，编译零报错**。已四次同源踩坑——L-7 PaneHead 折叠箭头、Z2
 * `UtilityDialogAction.enabled`（EM-B2）、v1.46 46.7 `label`（U-01）、2026-11-09
 * 回收站折叠箭头（TrashView / VaultSidebar / NoteDialogs 共 4 处，v1.47 47.1 已修）。
 *
 * 规则：`Icon(` 调用的任一实参含 `this.` 即失败。状态依赖的正确写法：
 *  - 图标名 / 颜色随状态切换 → **if/else 分支**（分支受状态观察，切换时销毁重建）；
 *  - 行级重建已覆盖刷新的场景（ForEach/LazyForEach 键含状态）→ 进豁免清单注明理由。
 * 豁免清单条目失效（调用被修复 / 删除）必须同步删除，过期条目同样报错。
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

/**
 * 从 openParenIndex（指向 `Icon(` 的 `(`）提取平衡括号内的实参文本。
 * 跨行安全；跳过字符串字面量内容（防中文全角 / 括号干扰计数）。
 */
export function extractIconArgs(source, openParenIndex) {
  let depth = 1;
  let i = openParenIndex + 1;
  let out = [];
  let quote = null;
  while (i < source.length && depth > 0) {
    const ch = source[i];
    if (quote !== null) {
      out.push(ch);
      if (ch === '\\') {
        i++;
        if (i < source.length) out.push(source[i]);
      } else if (ch === quote) {
        quote = null;
      }
    } else if (ch === '\'' || ch === '"' || ch === '`') {
      quote = ch;
      out.push(ch);
    } else if (ch === '(') {
      depth++;
      out.push(ch);
    } else if (ch === ')') {
      depth--;
      if (depth > 0) out.push(ch);
    } else {
      out.push(ch);
    }
    i++;
  }
  return out.join('');
}

/** 找出全部 `Icon(` 调用（词边界排除 enterIcon 等；`function Icon(` 定义跳过） */
export function findIconCalls(source) {
  const calls = [];
  const re = /\bIcon\(/g;
  let m;
  while ((m = re.exec(source)) !== null) {
    const before = source.slice(Math.max(0, m.index - 40), m.index);
    if (/function\s+$/.test(before)) continue;
    const openParen = m.index + m[0].length - 1;
    const args = extractIconArgs(source, openParen);
    const line = source.slice(0, m.index).split('\n').length;
    calls.push({ args, line });
  }
  return calls;
}

/**
 * 豁免清单 —— 实参含 `this.` 的存量调用点（2026-11-09 全量盘点）。
 * kind:
 *  - 'safe'   已验证不依赖实参刷新：行键含状态（重建）、if 分支重建、
 *             弹层打开时构建、实参只依赖行数据 / 构造期定值；
 *  - 'frozen' 已知冻结缺陷（W-01 待修），修复后必须删除条目。
 * expectHits：needle 应命中的调用点数（默认 1；实参文本完全相同的多处共用一条）。
 */
const ALLOWED = [
  // ---- safe：行键含状态，切换时整行重建 ----
  {
    file: 'components/FileTreeView.ets',
    needle: "this.isExpanded(n.relPath) ? 'chevronDown'",
    kind: 'safe',
    reason: 'LazyForEach 目录键含折叠态 |e/|c（键生成器 :690），折叠切换整行重建',
  },
  {
    file: 'components/FileTreeView.ets',
    needle: 'n.relPath === this.currentFilePath',
    kind: 'safe',
    reason: '文件键含选中态 |s/|u（键生成器 :692），选中变化整行重建；目录分支实参不含状态',
  },
  {
    file: 'components/VaultSidebar.ets',
    needle: 'this.isChapterCollapsed(chapter) ? \'chevronRight\'',
    kind: 'safe',
    reason: '章节 ForEach 键含 foldState + selectedState（:719-724），折叠切换整行重建',
  },
  // ---- safe：节点由分支 / 弹层在状态生效时新建 ----
  {
    file: 'components/VaultSidebar.ets',
    needle: 'v.id === this.currentVaultId',
    kind: 'safe',
    reason: 'bindPopup 弹层内容打开时构建；切换库即关闭弹层，无陈旧窗口',
  },
  {
    file: 'components/GitSyncDialog.ets',
    needle: "this.result === 'success' ? 'check' : 'doc'",
    kind: 'safe',
    reason: 'ResultPanel 在 if (this.result !== \'none\') 内，结果翻转时新建节点',
  },
  // ---- safe：实参不依赖组件状态 ----
  {
    file: 'components/ShareFilePreviewDialog.ets',
    needle: 'this.entryIcon(path)',
    kind: 'safe',
    reason: '实参只依赖行数据 path（后缀判断），无状态依赖',
  },
  {
    file: 'components/UtilityDialogShell.ets',
    needle: 'this.headerIcon, Space.s5',
    kind: 'safe',
    reason: 'headerIcon 为普通成员，每次弹窗打开新建 shell 实例时定值，生命周期内不变',
  },
  // ---- frozen：W-01 待修批次（修复后删除条目）----
  {
    file: 'components/GitSyncDialog.ets',
    needle: 'index <= this.completedStep',
    kind: 'frozen',
    reason: 'W-01：同步步骤图标固化于挂载帧（ProgressSteps 外层 if 挂载时求值，ForEach 键=label 不变）',
  },
  {
    file: 'components/NoteDialogs.ets',
    needle: 'this.selectedDir === rel',
    kind: 'frozen',
    expectHits: 2,
    reason: 'W-01：CreateNoteDialog / MovePathDialog 两个 DirItem 的文件夹图标选中色固化（文字色正常刷新）',
  },
  {
    file: 'pages/Index.ets',
    needle: "this.focused ? 'exitFocus' : 'focus'",
    kind: 'frozen',
    reason: 'W-01：FocusModeButton 图标名 + 色固化于首帧',
  },
  {
    file: 'pages/Index.ets',
    needle: 'this.isReferenceShown()',
    kind: 'frozen',
    reason: 'W-01：ReferencePaneButton 图标色固化（背景色属性正常刷新）',
  },
  {
    file: 'pages/Index.ets',
    needle: 'this.isImagePickerBusy(pane)',
    kind: 'frozen',
    reason: 'W-01：ImageFormatAction 图标色固化（accessibilityText 属性正常刷新）',
  },
  {
    file: 'components/SettingsView.ets',
    needle: 'this.experienceMode === mode',
    kind: 'frozen',
    reason: 'W-01：体验模式行图标选中色固化（文字 / 字重属性正常刷新）',
  },
  {
    file: 'components/ImportVaultDialog.ets',
    needle: "this.directoryState === 'failed'",
    kind: 'frozen',
    reason: "W-01：目录导入 Stack 图标失败色固化（'selected' 的 check 分支正常刷新）",
  },
  {
    file: 'components/ImportVaultDialog.ets',
    needle: "this.zipState === 'failed'",
    kind: 'frozen',
    reason: "W-01：ZIP 导入 Stack 图标失败色固化（'selected' 的 check 分支正常刷新）",
  },
  {
    file: 'components/AgentWorkspace.ets',
    needle: 'session.id === this.sessionId',
    kind: 'frozen',
    reason: 'W-01：会话列表图标选中色固化（ForEach 键=id+title，不含 sessionId）',
  },
];

const files = walk(etsRoot);

test('Icon() call args must not reference component state (this.) without an allowlist entry', () => {
  const violations = [];
  for (const file of files) {
    const rel = relative(etsRoot, file);
    const source = readFileSync(file, 'utf8');
    for (const call of findIconCalls(source)) {
      if (!call.args.includes('this.')) continue;
      const entry = ALLOWED.find((e) => e.file === rel && call.args.includes(e.needle));
      if (!entry) {
        violations.push(`${rel}:${call.line} -> ${call.args.replace(/\s+/g, ' ').slice(0, 120)}`);
      }
    }
  }
  assert.deepEqual(
    violations, [],
    `全局 @Builder 按值实参会首帧固化（api_notes Z2/L-7），实参含 this. 必须走 if/else 分支或进豁免清单：\n${violations.join('\n')}`
  );
});

test('every allowlist entry still matches the expected number of live Icon() calls', () => {
  const stale = [];
  for (const entry of ALLOWED) {
    const expected = entry.expectHits ?? 1;
    const source = readFileSync(join(etsRoot, entry.file), 'utf8');
    const hits = findIconCalls(source)
      .filter((c) => c.args.includes('this.') && c.args.includes(entry.needle)).length;
    if (hits !== expected) {
      stale.push(`${entry.file} -> 「${entry.needle}」期望 ${expected} 处，实际 ${hits} 处（调用已修复 / 删除，请同步更新或删除豁免条目）`);
    }
  }
  assert.deepEqual(stale, [], `豁免清单过期：\n${stale.join('\n')}`);
});

test('frozen backlog stays tracked: W-batch entries exist while any frozen allowlist entry remains', () => {
  const frozen = ALLOWED.filter((e) => e.kind === 'frozen');
  if (frozen.length === 0) return;
  const backlog = readFileSync(join(repoRoot, 'docs/requirements_backlog.md'), 'utf8');
  assert.ok(
    /W-01/.test(backlog),
    '豁免清单仍有 frozen 条目时，需求池必须保留 W-01（图标冻结待修批次）跟踪'
  );
});
