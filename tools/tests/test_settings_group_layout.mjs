import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { readSourceFile } from './lib/source.mjs';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');

const source = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const prototype = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

function slice(startMarker, endMarker) {
  const start = source.indexOf(startMarker);
  assert.ok(start >= 0, `missing ${startMarker}`);
  const end = endMarker ? source.indexOf(endMarker, start) : source.length;
  assert.ok(end > start, `missing end for ${startMarker}`);
  return source.slice(start, end);
}

test('general tab uses group titles outside the cards, matching .hs-group-title', () => {
  assert.match(prototype, /\.hs-group-title\{margin:var\(--s5\) var\(--s4\) var\(--s2\);font-size:var\(--caption\);font-weight:500;color:var\(--muted\)/);
  assert.match(source, /GroupTitle\(text: string\)/);
  assert.match(source, /\.fontSize\(FontSize\.caption\)\s*\n\s*\.fontWeight\(FontWeight\.Medium\)\s*\n\s*\.fontColor\(\$r\('app\.color\.text_tertiary'\)\)/);
  for (const title of ['外观', '编辑器', '阅读与编辑布局', '高级', '本地数据', '更新日志']) {
    assert.match(source, new RegExp(`this\\.GroupTitle\\('${title}'\\)`), `缺少分组标题 ${title}`);
  }
  // 编辑模式标题带键盘焦点进入，样式与其它分组标题一致。
  assert.match(source, /Text\('编辑模式'\)\s*\n\s*\.fontSize\(FontSize\.caption\)/);
  assert.match(source, /onExperienceModeHeadingKey/);
});

test('data tab presents a danger row with in-group confirmation instead of a dialog', () => {
  assert.match(source, /this\.GroupTitle\('本地数据'\)/);
  assert.match(source, /Text\(this\.resetting \? '正在重置…' : '重置所有数据…'\)/);
  assert.match(source, /\.fontColor\(\$r\('app\.color\.danger'\)\)/);
  assert.match(source, /Text\('确定重置所有数据？'\)/);
  assert.match(source, /Text\('取消'\)/);
  assert.match(source, /Text\('重置并恢复样例'\)/);
  // 两步防误触：先点行展开，再点确认；不再走弹窗。
  assert.match(source, /private openResetConfirm\(\): void \{/);
  assert.match(source, /this\.resetConfirmOpen = true;/);
  assert.doesNotMatch(source, /ResetDataDialog/);
  // 语义不变：仍走同一个 AppDataResetService.reset，失败反馈不暴露系统异常。
  assert.match(source, /await AppDataResetService\.reset\(getContext\(this\) as common\.UIAbilityContext\);/);
  assert.match(source, /'重置未完成；部分访问令牌可能已清除，本地数据清理状态未确认。'/);
  assert.doesNotMatch(source, /this\.resetError\s*=\s*'[^']*'\s*\+\s*err\.message/);
  assert.match(source, /会清除本地笔记库、草稿、回收站、最近打开、同步配置和访问令牌/);
});

test('reset confirmation stays closed until the danger row is pressed', () => {
  const code = transformSync(`class ResetConfirmHarness {
  ${slice('  private openResetConfirm(): void {', '\n  private async resetData')}
  constructor() { this.resetting = false; this.resetConfirmOpen = false; }
}; module.exports = ResetConfirmHarness;`, { loader: 'ts', format: 'cjs' }).code;
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
  const app = new module.exports();

  app.openResetConfirm();
  assert.equal(app.resetConfirmOpen, true);

  app.resetConfirmOpen = false;
  app.resetting = true;
  app.openResetConfirm();
  assert.equal(app.resetConfirmOpen, false, '重置进行中不能再展开确认');
});

test('about tab centres the hero like .hs-hero and keeps policy and changelog entries', () => {
  assert.match(prototype, /\.hs-hero\{display:flex;flex-direction:column;align-items:center;text-align:center/);
  assert.match(source, /Text\('曜石笔记'\)/);
  assert.match(source, /Text\('为 XT2 三折叠做的本地 Markdown 笔记'\)/);
  const hero = slice('  AboutTab() {', "\n      this.GroupTitle('更新日志')");
  assert.match(hero, /alignItems\(HorizontalAlign\.Center\)/);
  assert.match(hero, /Image\(\$r\('app\.media\.app_icon_1024'\)\)/);
  assert.match(source, /accessibilityText\('查看隐私政策'\)/);
  assert.match(source, /ChangelogList\(\{ entries: RECENT_CHANGELOG \}\)/);
  assert.match(source, /Span\(FEEDBACK_EMAIL\)/);
});

test('feedback tab drops the duplicated heading and keeps the mail entry', () => {
  const start = source.indexOf('  FeedbackTab() {');
  assert.ok(start >= 0, 'missing FeedbackTab');
  const next = source.indexOf('\n  @Builder', start + 10);
  const feedback = source.slice(start, next < 0 ? source.length : next);
  assert.equal((feedback.match(/Text\('问题与建议'\)/g) ?? []).length, 1,
    '页标题之外不应再重复一次「问题与建议」');
  assert.match(feedback, /TextArea\(\{ text: this\.feedbackSteps \}\)/);
  assert.match(feedback, /TextArea\(\{ text: this\.feedbackActual \}\)/);
  assert.match(feedback, /TextArea\(\{ text: this\.feedbackExpected \}\)/);
});

test('category navigation drops the highlight and arrow in the single-screen list', () => {
  const code = transformSync(`class CategoryHarness {
  ${slice('  private isCategoryListOnly(): boolean {', '\n  @Builder\n  CategoryRow')}
  constructor(options) { Object.assign(this, options); }
}; module.exports = CategoryHarness;`, { loader: 'ts', format: 'cjs' }).code;
  const module = { exports: {} };
  vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
  const Module = module.exports;

  const wide = new Module({ singleScreenLayout: false, showCategoryList: true, selectedTab: 'general' });
  assert.equal(wide.isCategoryListOnly(), false);
  assert.equal(wide.isCategoryHighlighted('general'), true);
  assert.equal(wide.isCategoryHighlighted('data'), false);

  const single = new Module({ singleScreenLayout: true, showCategoryList: true, selectedTab: 'general' });
  assert.equal(single.isCategoryListOnly(), true);
  assert.equal(single.isCategoryHighlighted('general'), false, '单屏分类列表不该有选中态');

  const singleDetail = new Module({ singleScreenLayout: true, showCategoryList: false, selectedTab: 'general' });
  assert.equal(singleDetail.isCategoryListOnly(), false);
  assert.equal(singleDetail.isCategoryHighlighted('general'), true, '单屏详情态仍是详情并列，保留选中态');

  assert.match(source, /if \(showArrow && !this\.isCategoryListOnly\(\)\) \{/);
  assert.match(source, /backgroundColor\(this\.isCategoryHighlighted\(category\)/);
});
