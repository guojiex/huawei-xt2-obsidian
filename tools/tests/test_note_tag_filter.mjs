/*
 * v2.11 标签浏览与过滤 —— 防线测试（需求文档 211.6）。
 *
 * 覆盖三层：
 *  1. 行为级：NoteTagParser 纯函数（frontmatter 各形态 / 行内 #tag /
 *     代码·公式排除 / 纯数字拒绝 / 小写去重保首书写形 / frontmatter 优先）、
 *     FileTree.taggedNotes（交集 / 排序 / 去重 / 陈旧路径跳过）——
 *     源码切片 + esbuild + vm 裸跑（仿 test_file_favorites.mjs）。
 *  2. 源级：search_tags 表 + schema 升版 + 写入/删除连带清理、服务层接线、
 *     FileTreeView 过滤条 / 过滤列表 / 清除出口、VaultSidebar 标签页签（改稿二：
 *     TagsPanel / TagRow / tagRows 透传）、Index 状态与 chip 消费链、
 *     tagCounts 上提（refreshTagRows）、切库清过滤、PreviewWebView 桥、
 *     mdpreview chip 化与 rawfile 产物同步（已知坑 3）。
 *  3. 红线：标签值不进日志/埋点（硬约束 16）；新增样式只引 token（硬约束 17）；
 *     权限零新增（硬约束 13）。
 *
 * 排序断言只用 ASCII 数据：zh localeCompare 的拼音序由设备侧保证，
 * Node 侧 ICU 配置差异不该让本测试抖动（结构保证 = 文件夹路径序 / 同夹标题序；
 * 根目录键无前缀、与目录一起排路径序，原型口径 'a/note1' < 'note1'）。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

/* ---------------- 源码载入 ---------------- */

const parserSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/NoteTagParser.ets', import.meta.url));
const fileTreeSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/FileTree.ets', import.meta.url));
const searchStoreSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/SearchStore.ets', import.meta.url));
const storeDeviceSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/SearchStoreDevice.ets', import.meta.url));
const serviceSource = readSourceFile(
  new URL('../../entry/src/main/ets/model/FullTextSearchService.ets', import.meta.url));
const fileTreeViewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url));
const sidebarSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url));
const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const previewSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/PreviewWebView.ets', import.meta.url));
const rendererSource = readSourceFile(
  new URL('../../web/mdpreview/src/renderer.mjs', import.meta.url));
const mdpreviewIndexSource = readSourceFile(
  new URL('../../web/mdpreview/src/index.ts', import.meta.url));
const moduleJson5 = readSourceFile(
  new URL('../../entry/src/main/module.json5', import.meta.url));
const rawfileHtml = fs.readFileSync(
  new URL('../../entry/src/main/resources/rawfile/mdpreview/index.html', import.meta.url), 'utf8');

function loadParser() {
  const code = transformSync(parserSource, { loader: 'ts', format: 'cjs' }).code;
  const context = vm.createContext({ module: { exports: {} }, console });
  vm.runInContext(code, context);
  return context.module.exports;
}

/** 切出 FileTree 类体（纯静态工具类，无系统依赖）塞进 vm。 */
function loadFileTree() {
  const start = fileTreeSource.indexOf('export class FileTree');
  const end = fileTreeSource.indexOf('export class ExpandStore');
  assert.ok(start >= 0 && end > start, '找不到 FileTree 类体');
  const code = transformSync(
    fileTreeSource.slice(start, end).replace('export class', 'class') +
    '\nmodule.exports = { FileTree };', { loader: 'ts', format: 'cjs' }).code;
  const context = vm.createContext({ module: { exports: {} }, console });
  vm.runInContext(code, context);
  return context.module.exports.FileTree;
}

/** vm realm 的数组与主 realm 原型不同，deepStrictEqual 会判不等，先过 JSON 归一。 */
function plain(values) {
  return JSON.parse(JSON.stringify(values));
}

function eq(actual, expected) {
  assert.deepEqual(plain(actual), expected);
}

/* ================= 行为级：NoteTagParser（211.2） ================= */

test('isValidTag：字符集合法且非纯数字', () => {
  const parser = loadParser();
  assert.equal(parser.isValidTag('工作'), true);
  assert.equal(parser.isValidTag('v2.11'), true);
  assert.equal(parser.isValidTag('a-b_c/d'), true);
  assert.equal(parser.isValidTag('项目/子'), true);
  assert.equal(parser.isValidTag('123'), false); // 纯数字拒绝
  assert.equal(parser.isValidTag(''), false);
  assert.equal(parser.isValidTag('a b'), false); // 空格不在字符集
});

test('splitNoteFrontmatter：无 frontmatter / --- / ... / CRLF / BOM', () => {
  const parser = loadParser();
  eq(parser.splitNoteFrontmatter('hello'), { frontmatter: '', body: 'hello' });
  const split = parser.splitNoteFrontmatter('---\ntags: [a]\n---\nbody');
  assert.equal(split.frontmatter, '---\ntags: [a]\n---\n');
  assert.equal(split.body, 'body');
  assert.equal(parser.splitNoteFrontmatter('---\ntags: a\n...\nbody').frontmatter.length > 0, true);
  assert.equal(parser.splitNoteFrontmatter('---\r\ntags: a\r\n---\r\nbody').frontmatter.length > 0, true);
  assert.equal(parser.splitNoteFrontmatter('\uFEFF---\ntags: a\n---\nbody').frontmatter.length > 0, true);
});

test('frontmatterTags：行内列表 + # 前缀', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ntags: [工作, #项目]\n---\n正文'), ['工作', '项目']);
});

test('frontmatterTags：块列表 + 双引号 JSON 值', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ntags:\n  - 鸿蒙\n  - "笔记应用"\n---\n'), ['鸿蒙', '笔记应用']);
});

test('frontmatterTags：单引号值与 \'\' 转义', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags("---\ntags: ['it''s', plain]\n---\n"), ["it's", 'plain']);
});

test('frontmatterTags：裸值 + 行尾注释剥离', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ntags: foo # comment\n---\n'), ['foo']);
});

test('frontmatterTags：双引号 JSON 解引号（含空格值）', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ntags: ["a b", "c"]\n---\n'), ['a b', 'c']);
});

test('frontmatterTags：纯数字拒绝、JSON 解析失败跳过、解出非法字符集跳过', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ntags: [1, 2]\n---\n'), []);
  eq(parser.frontmatterTags('---\ntags: ["\\x", ok]\n---\n'), ['ok']);
  eq(parser.frontmatterTags('---\ntags: ["[1,2]", ok]\n---\n'), ['ok']);
});

test('frontmatterTags：小写去重、保留首个书写形式', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ntags: [Tag, tag, TAG]\n---\n'), ['Tag']);
});

test('frontmatterTags：其它键不误读；块列表遇非缩进行终止', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('---\ncategory: x\ntags:\n  - a\ntitle: y\n- b\n---\n'), ['a']);
});

test('frontmatterTags：无 frontmatter 返回空', () => {
  const parser = loadParser();
  eq(parser.frontmatterTags('#tag 正文'), []);
});

test('inlineTags：行首 / 空白 / 半角·全角括号边界', () => {
  const parser = loadParser();
  eq(parser.inlineTags('#工作'), ['工作']);
  eq(parser.inlineTags('正文 #标签 继续'), ['标签']);
  eq(parser.inlineTags('（#中文）'), ['中文']);
  eq(parser.inlineTags('(#half)'), ['half']);
});

test('inlineTags：fenced code / 行内 code / 块公式 / 行内公式全部排除', () => {
  const parser = loadParser();
  eq(parser.inlineTags('```js\n#not\n```\n#real'), ['real']);
  eq(parser.inlineTags('`#not` #real'), ['real']);
  eq(parser.inlineTags('$$\n#m\n$$ #real'), ['real']);
  eq(parser.inlineTags('$#x$ #real'), ['real']);
});

test('inlineTags：纯数字拒绝、标题不误报、frontmatter 不参与', () => {
  const parser = loadParser();
  eq(parser.inlineTags('#123'), []);
  eq(parser.inlineTags('# 标题'), []);
  eq(parser.inlineTags('---\ntags: [x]\n---\n#y'), ['y']);
});

test('inlineTags：字符集（连字符/下划线/斜杠/中文嵌套）与小写去重保首', () => {
  const parser = loadParser();
  eq(parser.inlineTags('#a-b_c/d'), ['a-b_c/d']);
  eq(parser.inlineTags('#项目/子'), ['项目/子']);
  eq(parser.inlineTags('#Tag #tag #TAG'), ['Tag']);
});

test('noteTagList：frontmatter 优先于行内，跨来源小写去重', () => {
  const parser = loadParser();
  eq(parser.noteTagList('---\ntags: [Tag]\n---\n#tag #other'), ['Tag', 'other']);
  eq(parser.noteTagList('---\ntags: [a]\n---\n#b'), ['a', 'b']);
  eq(parser.noteTagList('plain text'), []);
});

/* ================= 行为级：FileTree.taggedNotes（211.4） ================= */

test('taggedNotes：交集过滤 + 文件夹路径序 + 去重 + 陈旧路径跳过', () => {
  const FileTree = loadFileTree();
  const allNotes = ['b/note2.md', 'note1.md', 'a/note3.md', 'a/note1.md'];
  const paths = ['a/note3.md', 'gone/stale.md', 'note1.md', 'b/note2.md', 'a/note1.md', 'note1.md'];
  const rows = FileTree.taggedNotes(allNotes, paths);
  // 根目录键无前缀、与目录一起按「文件夹完整路径 + 标题」zh 排序（对齐原型过滤分支）：
  // 'a/note1' < 'a/note3' < 'b/note2' < 'note1'
  eq(rows.map((row) => row.relPath), ['a/note1.md', 'a/note3.md', 'b/note2.md', 'note1.md']);
  const nested = rows[0];
  assert.equal(nested.folder, 'a');
  assert.equal(nested.folderPath, 'a');
  assert.equal(typeof nested.tone, 'number');
  const root = rows[3];
  assert.equal(root.title, 'note1');
  assert.equal(root.folder, '根目录');
  assert.equal(root.folderPath, '');
  assert.equal(root.initial, 'N');
});

test('taggedNotes：同文件夹按标题排序，标题剥 .md / .markdown 扩展名', () => {
  const FileTree = loadFileTree();
  const rows = FileTree.taggedNotes(['docs/b.md', 'docs/a.md', 'docs/y.markdown'],
    ['docs/b.md', 'docs/y.markdown', 'docs/a.md']);
  eq(rows.map((row) => row.relPath), ['docs/a.md', 'docs/b.md', 'docs/y.markdown']);
  eq(rows.map((row) => row.title), ['a', 'b', 'y']);
});

test('taggedNotes：空入参与全空集安全返回', () => {
  const FileTree = loadFileTree();
  eq(FileTree.taggedNotes([], ['a.md']), []);
  eq(FileTree.taggedNotes(['a.md'], []), []);
});

/* ================= 源级：数据层（211.1） ================= */

test('search.db：search_tags 建表 + schema 升版 2 + 整库重建连带 DROP', () => {
  assert.match(storeDeviceSource, /const SCHEMA_VERSION: string = '2';/);
  assert.match(storeDeviceSource, /CREATE TABLE IF NOT EXISTS search_tags/);
  assert.match(storeDeviceSource, /DROP TABLE IF EXISTS search_tags/);
});

test('search.db：tagCounts 聚合 SQL（GROUP BY tag_key、MIN(tag) 保首个书写形）', () => {
  assert.ok(storeDeviceSource.includes(
    'SELECT tag_key, MIN(tag), COUNT(*) FROM search_tags WHERE vault_key = ? GROUP BY tag_key'));
});

test('search.db：pathsForTag 查询 SQL（按 path 排序）', () => {
  assert.ok(storeDeviceSource.includes(
    'SELECT path FROM search_tags WHERE vault_key = ? AND tag_key = ? ORDER BY path'));
});

test('search.db：upsert 整篇替换 + 删除/清库连带清理 tag 行', () => {
  assert.ok(storeDeviceSource.includes(
    'INSERT OR REPLACE INTO search_tags (vault_key, tag_key, tag, path) VALUES (?, ?, ?, ?)'));
  // 删除文档（删除/移动/重命名/回收站）与全文删除两处共用同一条按路径清理
  const byPath = storeDeviceSource.match(
    /DELETE FROM search_tags WHERE vault_key = \? AND path = \?/g) ?? [];
  assert.equal(byPath.length, 2);
  assert.ok(storeDeviceSource.includes('DELETE FROM search_tags WHERE vault_key = ?'));
});

test('SearchStore：TagCountRow 契约与接口方法', () => {
  const rowStart = searchStoreSource.indexOf('export interface TagCountRow');
  assert.ok(rowStart >= 0, '缺 TagCountRow 导出');
  const rowBlock = searchStoreSource.slice(rowStart, rowStart + 400);
  assert.match(rowBlock, /tag: string;/);
  assert.match(rowBlock, /tagKey: string;/);
  assert.match(rowBlock, /noteCount: number;/);
  assert.match(searchStoreSource, /tagCounts\(vaultKey: string\): Promise<TagCountRow\[\]>;/);
  assert.match(searchStoreSource, /pathsForTag\(vaultKey: string, tagKey: string\): Promise<string\[\]>;/);
});

/* ================= 源级：服务层（211.1 写入载荷） ================= */

test('FullTextSearchService：upsert 载荷用 noteTagList；tagCounts/pathsForTag 降级空集口径', () => {
  assert.match(serviceSource, /import \{ noteTagList \} from '\.\/NoteTagParser';/);
  assert.ok(serviceSource.includes('tags: noteTagList(content)'));
  assert.match(serviceSource,
    /static async tagCounts\(registry: SearchVaultRegistry, vaultId: string\): Promise<TagCountRow\[\]>/);
  assert.match(serviceSource,
    /static async pathsForTag\(registry: SearchVaultRegistry, vaultId: string,/);
  // 零日志（隐私口径与正文搜索一致）
  assert.doesNotMatch(serviceSource, /hilog/);
  assert.doesNotMatch(serviceSource, /hiAppEvent/);
});

/* ================= 源级：FileTreeView（211.4 过滤链路，改稿二） ================= */

test('FileTreeView：tagFilter @Prop 镜像 + 回调 + 过滤行数据面', () => {
  assert.match(fileTreeViewSource,
    /@Prop @Watch\('onTagFilterChanged'\) tagFilter: string = '';/);
  assert.match(fileTreeViewSource, /onTagFilterChange: \(tag: string\) => void/);
  assert.match(fileTreeViewSource, /@State filterRows: PinnedNote\[\] = \[\];/);
  // 改稿二：药丸云 / tagRows / 折叠态全部上提，文件页签只留过滤链路
  assert.doesNotMatch(fileTreeViewSource, /tagRows|TagsSection|tagSectionOpen|drawerForm/);
});

test('FileTreeView：过滤行刷新链路（pathsForTag → taggedNotes）；Index：tagCounts 药丸行（改稿二上提）', () => {
  assert.ok(fileTreeViewSource.includes(
    'FullTextSearchService.pathsForTag(registry, this.vaultId, this.tagFilter.toLowerCase())'));
  assert.ok(fileTreeViewSource.includes('FileTree.taggedNotes(allNotes, paths)'));
  // 改稿二：tagCounts 聚合与 noteCount 降序排序上提 Index.refreshTagRows
  assert.ok(indexSource.includes('FullTextSearchService.tagCounts(registry, vaultId)'));
  assert.ok(indexSource.includes('return a.noteCount > b.noteCount ? -1 : 1;'));
});

test('FileTreeView：清除过滤唯一出口 + Index：过滤标签查不到时防御性退出', () => {
  // 过滤条 / 「清除筛选」都走 clearTagFilter → 上报清空（211.1）
  const exits = fileTreeViewSource.match(/this\.onTagFilterChange\(''\);/g) ?? [];
  assert.equal(exits.length, 1);
  // 改稿二：聚合里查不到过滤中的标签（删光 / 改写）→ Index.refreshTagRows 防御退出（211.6）
  assert.ok(indexSource.includes('this.setTagFilter(\'\');'));
});

test('FileTreeView：build 分区顺序（置顶→收藏→过滤条→全部笔记→树）', () => {
  const order = ['this.PinSection()', 'this.FavSection()', 'this.TagFilterBar()',
    'this.AllNotesLabel()', 'this.TreeList()'];
  let prev = -1;
  for (const marker of order) {
    const at = fileTreeViewSource.indexOf(marker);
    assert.ok(at > prev, `build 顺序错位：${marker}`);
    prev = at;
  }
  // 过滤态：置顶 / 收藏区隐藏；左滑提示行隐藏
  assert.ok(fileTreeViewSource.includes('!this.isTagFiltering()'));
  // 改稿二：标签分区不再占用文件页签（药丸云随「标签」页签进 VaultSidebar）
  assert.doesNotMatch(fileTreeViewSource, /this\.TagsSection\(\)/);
});

test('FileTreeView：空态文案与过滤行键；VaultSidebar：标签行键', () => {
  assert.ok(fileTreeViewSource.includes("Text('没有带「#' + this.tagFilter + '」的笔记')"));
  assert.ok(fileTreeViewSource.includes("'tagfilter-' + row.relPath"));
  assert.ok(sidebarSource.includes("'tagrow-' + row.tagKey"));
});

/* ================= 源级：VaultSidebar 标签页签（211.3 改稿二） ================= */

test('VaultSidebar：tagFilter 透传 FileTreeView + tagRows 面板数据', () => {
  assert.match(sidebarSource, /@Prop tagFilter: string = '';/);
  assert.match(sidebarSource, /@Prop tagRows: TagCountRow\[\] = \[\];/);
  assert.match(sidebarSource, /onTagFilterChange: \(tag: string\) => void/);
  assert.ok(sidebarSource.includes('tagFilter: this.tagFilter,'));
  assert.ok(sidebarSource.includes('onTagFilterChange: (tag: string): void => { this.onTagFilterChange(tag); }'));
  // 改稿二：drawerForm 已随抽屉形态重构移除
  assert.doesNotMatch(sidebarSource, /drawerForm/);
});

test('VaultSidebar：TagsPanel / TagRow（点行置过滤并切回文件页签；再点取消）', () => {
  assert.ok(sidebarSource.includes('  TagsPanel() {'));
  assert.ok(sidebarSource.includes('  TagRow(row: TagCountRow) {'));
  // 面板标题 / 空态文案
  assert.ok(sidebarSource.includes("'标签 · ' + this.tagRows.length.toString() + ' 个'"));
  assert.ok(sidebarSource.includes("Text('还没有带标签的笔记')"));
  // 点行 toggle：置过滤自动切回文件页签；再点同一行取消、留在标签页签
  assert.ok(sidebarSource.includes('const next: string = row.tag === this.tagFilter ? \'\' : row.tag;'));
  assert.ok(sidebarSource.includes("this.onSidebarTabChange('files');"));
});

/* ================= 源级：Index（211.4 / 211.5 消费侧） ================= */

test('Index：过滤态唯一真源 + NoteNavigation 接线', () => {
  assert.match(indexSource, /@State activeTagFilter: string = '';/);
  assert.match(indexSource,
    /private setTagFilter\(tag: string\): void \{\s*\n\s*this\.activeTagFilter = tag;\s*\n\s*\}/);
  assert.ok(indexSource.includes('tagFilter: this.activeTagFilter,'));
  assert.ok(indexSource.includes('onTagFilterChange: (tag: string): void => { this.setTagFilter(tag); }'));
});

test('Index：handleNoteTagClick —— 匹配书写形、静默未命中、导航链、切库守卫', () => {
  const start = indexSource.indexOf('private handleNoteTagClick(tag: string): void {');
  assert.ok(start >= 0, '缺 handleNoteTagClick');
  const body = indexSource.slice(start, indexSource.indexOf('\n  }', start) + 4);
  assert.ok(body.includes('FullTextSearchService.tagCounts(registry, vaultId)'));
  assert.ok(body.includes('rows[i].tagKey === key'));
  assert.ok(body.includes('matched = rows[i].tag;'));
  assert.ok(body.includes('vaultId !== this.currentVaultId')); // 异步期间切库丢弃
  assert.ok(body.includes("this.setSidebarTab('files');"));
  assert.ok(body.includes('this.setDrawerOpen(true);'));
  assert.ok(body.includes('this.setTagFilter(matched);'));
  assert.ok(body.includes('.catch((): void => {});')); // 失败静默（211.4）
  assert.ok(body.includes('if (this.focused)'));
});

test('Index：切库清过滤（switchVault 内清 activeTagFilter）', () => {
  const start = indexSource.indexOf('private async switchVault(');
  assert.ok(start >= 0, '缺 switchVault');
  const body = indexSource.slice(start, start + 20000);
  const clearAt = body.indexOf("this.activeTagFilter = '';");
  assert.ok(clearAt >= 0, 'switchVault 未清 activeTagFilter');
  // 清理动作必须在切库生效（setCurrent）之后执行
  assert.ok(body.indexOf('VaultRegistry.get().setCurrent(') < clearAt);
});

test('Index：两栏 PreviewWebView 都接 onNoteTagClick', () => {
  const wired = indexSource.match(/onNoteTagClick:\s*\(tag: string\): void =>/g) ?? [];
  assert.equal(wired.length, 2);
  assert.match(indexSource, /import \{ SearchOutcome, TagCountRow \} from '\.\.\/model\/SearchStore';/);
});

/* ================= 源级：PreviewWebView 桥（211.5） ================= */

test('PreviewWebView：javaScriptProxy 注册 onNoteTagClick + base64 解码', () => {
  assert.match(previewSource, /onNoteTagClick\(tagB64: string\): void/);
  assert.ok(previewSource.includes('this.onNoteTagClick(BridgeCodec.decode(tagB64))'));
  assert.ok(previewSource.includes("'onNoteTagClick']")); // proxy 方法名注册
  assert.match(previewSource, /onNoteTagClick: \(tag: string\) => void/);
});

test('PreviewWebView：捕获阶段点击委托接管 chip（先于段落选中），UTF-8 base64 编码', () => {
  assert.ok(previewSource.includes('data-note-tag'));
  assert.ok(previewSource.includes("classList.contains('note-tag')"));
  assert.ok(previewSource.includes('btoa(unescape(encodeURIComponent('));
  assert.ok(previewSource.includes("typeof tagApi.onNoteTagClick==='function'"));
  assert.ok(previewSource.includes('addEventListener(\'click\'')); // click 委托（非 pointerdown 拦截）
});

/* ================= 源级：mdpreview chip 化 + 产物同步（211.5，已知坑 3） ================= */

test('mdpreview：chip 是 button（data-note-tag + 读屏名「按标签筛选」）', () => {
  assert.ok(rendererSource.includes('<button type="button" class="note-tag" data-note-tag='));
  assert.ok(rendererSource.includes('aria-label="按标签筛选：#'));
  assert.match(rendererSource, /export function frontmatterTags\(markdown\) \{/);
});

test('mdpreview：正文行内 #tag 走 noteTag token；Api 面新增 onNoteTagClick', () => {
  assert.match(rendererSource, /name: 'noteTag'/);
  assert.match(rendererSource, /type: 'noteTag'/);
  assert.ok(mdpreviewIndexSource.includes('onNoteTagClick?: (tagB64: string) => void'));
});

test('rawfile 产物已同步（含 chip 标记，已知坑 3）', () => {
  assert.ok(rawfileHtml.includes('data-note-tag'), 'rawfile 缺 chip 标记，需重跑 node build.mjs');
  assert.ok(rawfileHtml.includes('note-tag'));
});

/* ================= 红线：隐私（硬约束 16） ================= */

test('红线：标签值不进日志 / 埋点', () => {
  // NoteTagParser 文件头承诺零日志
  assert.doesNotMatch(parserSource, /hilog|hiAppEvent/);
  // 组件侧：标签过滤相关状态不进 hilog；四个改动文件零 hiAppEvent
  assert.doesNotMatch(fileTreeViewSource,
    /hilog\.(info|debug|warn|error)\([^)]*this\.(tagFilter|tagRows|filterRows|activeTagFilter)/);
  assert.doesNotMatch(indexSource,
    /hilog\.(info|debug|warn|error)\([^)]*(activeTagFilter|tagFilter|handleNoteTagClick)/);
  assert.doesNotMatch(fileTreeViewSource, /hiAppEvent/);
  assert.doesNotMatch(indexSource, /hiAppEvent/);
  assert.doesNotMatch(previewSource, /hiAppEvent/);
  assert.doesNotMatch(sidebarSource, /hiAppEvent/);
  // 设备层既有隐私口径沿用：错误日志不带标签值
  assert.doesNotMatch(storeDeviceSource, /hilog\.(info|debug|warn|error)\([^)]*[Tt]ag/);
});

/* ================= 红线：样式只引 token（硬约束 17） ================= */

test('红线：v2.11 新增 Builder 只引用 token，不散写数值', () => {
  // 改稿二：标签面板 Builder 区随「标签」页签进 VaultSidebar（TagsPanel → TagRow）
  const start = sidebarSource.indexOf('  TagsPanel() {');
  const end = sidebarSource.indexOf('  private vaultTypeLabel(');
  assert.ok(start >= 0 && end > start, '找不到 v2.11 Builder 区（VaultSidebar TagsPanel/TagRow）');
  const region = sidebarSource.slice(start, end);
  assert.match(region, /Space\./);
  assert.match(region, /Radius\./);
  assert.match(region, /Weight\.|FontWeight\./);
  // 散写数值禁令：字号 / 圆角 / 内边距 / 外边距 / 十六进制色（token 引用不受限）
  assert.doesNotMatch(region, /\.fontSize\(\s*\d/);
  assert.doesNotMatch(region, /\.borderRadius\(\s*\d/);
  assert.doesNotMatch(region, /\.padding\(\{[^}]*:\s*[1-9]/);
  assert.doesNotMatch(region, /\.margin\(\{[^}]*:\s*[1-9]/);
  assert.doesNotMatch(region, /#[0-9a-fA-F]{6}['"]/);
});

/* ================= 红线：权限零新增（硬约束 13） ================= */

test('红线：module.json5 权限面不变（INTERNET + FILE_ACCESS_PERSIST）', () => {
  assert.ok(moduleJson5.includes('ohos.permission.INTERNET'));
  assert.ok(moduleJson5.includes('ohos.permission.FILE_ACCESS_PERSIST'));
  assert.doesNotMatch(moduleJson5,
    /"name":\s*"ohos\.permission\.(?!INTERNET|FILE_ACCESS_PERSIST)/);
});
