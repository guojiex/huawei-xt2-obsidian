import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.31 31.1–31.6：单屏「…」菜单视觉整理 —— 三组 / 图标行 / 编辑模式分段 / 计数徽标 / 禁用态 / 外形。
const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const icons = readSourceFile(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const menuStart = index.indexOf('  MoreMenu() {');
const menuEnd = index.indexOf('\n  @Builder\n  NoteNavigation(', menuStart);
assert.ok(menuStart >= 0 && menuEnd > menuStart, 'could not find Index.MoreMenu');
const menu = index.slice(menuStart, menuEnd);

test('menu renders three groups in order: note / experience / app', () => {
  const noteGroup = menu.indexOf('MobileMoreMenuNoteGroup() {');
  const expGroup = menu.indexOf('MobileMoreMenuExperienceGroup() {');
  const appGroup = menu.indexOf('MobileMoreMenuAppGroup() {');
  assert.ok(noteGroup >= 0 && expGroup > noteGroup && appGroup > expGroup,
    'three group builders exist and are invoked in order');
  // 31.1 组内顺序：分享 → 反链 → 切换；应用组设置在末尾
  assert.ok(menu.indexOf("'share', 'share', '分享笔记'") <
    menu.indexOf("'backlinks', 'link',"), 'share precedes backlinks');
  assert.ok(menu.indexOf("'switch', 'swap',") > menu.indexOf("'backlinks', 'link',"),
    'switch follows backlinks');
  assert.ok(menu.indexOf('MobileMoreGitSyncItem()') <
    menu.indexOf("'settings', 'settings', '设置与关于'"), 'git sync precedes settings');
  // 切换仅两栏为不同笔记时
  assert.match(menu, /experienceMode === 'professional'[\s\S]*?currentFilePath !== this\.rightFilePath/);
  // 切换到笔记：标题去 .md（31.1 不显示带扩展名的文件名）
  assert.match(menu, /切换到笔记：' \+ \(this\.activeNotePane\(\) === 'left'[\s\S]*?paneNoteTitle\(this\.rightFilePath\)/);
});

test('icon rows use line icons, touch height, body font and ellipsis (31.2)', () => {
  const itemStart = menu.indexOf('MobileMoreMenuItem(action: string,');
  const itemEnd = menu.indexOf('\n  @Builder\n  MobileMoreSegButton(', itemStart);
  const item = menu.slice(itemStart, itemEnd);
  assert.match(item, /Icon\(icon, Space\.s5,/);
  assert.match(item, /FontSize\.body1/);
  assert.match(item, /\.height\(Size\.touch\)/);
  assert.match(item, /\.borderRadius\(Radius\.control\)/);
  assert.match(item, /\.maxLines\(1\)/);
  assert.match(item, /textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/);
  // 31.2 图标与顶栏/格式行同一套线稿：share/link/swap/rename/sync/settings 全部已有映射
  assert.match(icons, /name === 'share'/);
  assert.match(icons, /name === 'link'/);
  assert.match(icons, /name === 'swap'/);
  assert.match(icons, /name === 'rename'/);
  assert.match(icons, /name === 'sync'/);
  assert.match(icons, /name === 'settings'/);
});

test('experience mode is one row with a simple/professional segment (31.3)', () => {
  const expStart = menu.indexOf('MobileMoreMenuExperienceGroup() {');
  const expEnd = menu.indexOf('\n  @Builder\n  MobileMoreMenuAppGroup(', expStart);
  const exp = menu.slice(expStart, expEnd);
  assert.match(exp, /Icon\('rename', Space\.s5,/);
  assert.match(exp, /Text\('编辑模式'\)/);
  assert.match(exp, /FlexAlign\.SpaceBetween/);
  assert.match(exp, /MobileMoreSegButton\('simple', '简单'\)/);
  assert.match(exp, /MobileMoreSegButton\('professional', '专业'\)/);
  // 组间 --line 细分隔线
  assert.match(exp, /\.border\(\{ width: \{ top: 1 \}, color: \$r\('app\.color\.line'\) \}\)/);
  const segStart = menu.indexOf('MobileMoreSegButton(mode: EditorExperienceMode');
  const segEnd = menu.indexOf('\n  @Builder\n  MobileMoreGitSyncItem(', segStart);
  const seg = menu.slice(segStart, segEnd);
  assert.match(seg, /\? 600 : 400\)/);
  assert.match(seg, /app\.color\.brand_bg/);
  assert.match(seg, /app\.color\.brand'/);
  assert.match(seg, /Radius\.full/);
  assert.match(seg, /void this\.selectEditorExperience\(mode\)/);
  assert.match(seg, /this\.moreMenuOpen = false;/);
});

test('git ahead count is a blue pill badge, not link-style text (31.4)', () => {
  const gitStart = menu.indexOf('MobileMoreGitSyncItem() {');
  const gitEnd = menu.indexOf('\n  @Builder\n  NoteNavigation(', gitStart);
  const git = menu.slice(gitStart, gitEnd);
  assert.match(git, /gitAheadBadgeLabel\(\)/);
  assert.match(git, /app\.color\.on_brand/);
  assert.match(git, /app\.color\.brand'/);
  assert.match(git, /Radius\.full/);
  assert.match(git, /lineHeight\(Space\.s5\)/);
  assert.match(git, /constraintSize\(\{ minWidth: Space\.s5 \}\)/);
  // 读屏「N 个提交待推送」
  assert.match(git, /' 个提交待推送'/);
  // 不再呈现为蓝色链接样式小字
  assert.doesNotMatch(git, /' 个待推送'/);
});

test('note actions dim to 40% and stay disabled when no note is open (31.5)', () => {
  assert.match(menu, /\.opacity\(isEnabled \? 1 : 0\.4\)/);
  assert.match(menu, /\.enabled\(isEnabled\)/);
  assert.match(menu, /this\.activeFilePath\(\)\.length > 0, \(\): void => \{\s*this\.openShareNoteDialog\(\);/);
  assert.match(menu, /this\.activeFilePath\(\)\.length > 0, \(\): void => \{\s*this\.toggleBacklinks\(this\.activeNotePane\(\)\);/);
});

test('menu shell matches the v2 mobile-top-more spec (31.6)', () => {
  const shellStart = menu.indexOf('  MoreMenu() {');
  const shellEnd = menu.indexOf('\n  @Builder\n  MobileMoreMenuNoteGroup(', shellStart);
  const shell = menu.slice(shellStart, shellEnd);
  assert.match(shell, /\.width\(Space\.s16 \* 4\.25\)/);
  assert.doesNotMatch(shell, /\.constraintSize\(/);
  assert.match(shell, /\.padding\(\{ top: Space\.s1, bottom: Space\.s1 \}\)/);
  assert.match(shell, /Radius\.menu/);
  assert.match(shell, /Shadow\.floatBlur/);
  // Escape 关闭并把焦点还给「…」
  assert.match(shell, /KEYCODE_ESCAPE/);
  assert.match(shell, /requestFocus\('workspace-more-button'\)/);
  // 原型侧同名规则（min-width s16×4.25 / 上下 s1 / --r 圆角 / 组间线 / 禁用 40% / 徽标）
  assert.match(prototype, /\.mobile-top-more \.pane-more-menu\{min-width:calc\(var\(--s16\) \* 4\.25\);padding:var\(--s1\) 0;border-radius:var\(--r\)\}/);
  assert.match(prototype, /\.mobile-top-more \.menu-group\+\.menu-group\{border-top:var\(--stroke\) solid var\(--line\)\}/);
  assert.match(prototype, /\.mobile-top-more \.menu-group>button:disabled\{opacity:\.4\}/);
  assert.match(prototype, /\.mobile-top-more \.git-sync-count\{flex:none;min-width:var\(--s5\);height:var\(--s5\);padding:0 var\(--s1\);border-radius:var\(--pill\);background:var\(--blue\);color:var\(--paper\)/);
  assert.match(prototype, /\.mobile-top-more \.menu-seg button\[aria-pressed=true\]\{background:var\(--blue-soft\);color:var\(--blue\);font-weight:600/);
});

test('menu actions still trigger the original operations', () => {
  assert.match(index, /this\.openShareNoteDialog\(\);/);
  assert.match(index, /this\.toggleBacklinks\(this\.activeNotePane\(\)\);/);
  assert.match(index, /this\.toggleActivePane\(\);/);
  assert.match(index, /void this\.openGitSyncPage\(\);/);
  assert.match(index, /this\.openSettings\('note', 'general'\);/);
});
