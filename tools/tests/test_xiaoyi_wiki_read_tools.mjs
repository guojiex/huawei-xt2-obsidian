import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../../entry/src/main/ets/entryability/InsightIntentNoteService.ets', import.meta.url),
  'utf8');

function extractStaticMethod(name) {
  const start = source.indexOf(`private static ${name}(`);
  assert.ok(start >= 0, `could not find ${name}`);
  const open = source.indexOf('{', start);
  assert.ok(open > start, `could not find ${name} body`);
  let depth = 1;
  let end = open + 1;
  while (depth > 0 && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0, `could not parse ${name} body`);
  return source.slice(start, end).replace(`private static ${name}`, `function ${name}`);
}

const names = ['parseLimit', 'parseOffset', 'parseCursor', 'encodeCursor', 'buildSnippet', 'lineOfOffset',
  'buildOutline', 'planChunk', 'collectTreeEntries', 'withinDepth', 'relativeDepth', 'countNotesUnder',
  'inFolder', 'lastSegment', 'isoDate', 'outputChars', 'fitJsonArrayCount', 'fitChunkToOutputBudget',
  'fitPage', 'ensureOutputBudget', 'parseReadOnlyFolders', 'isReadOnlyPath'];
const methods = names.map(extractStaticMethod).join('\n').replace(/InsightIntentNoteService\./g, '');

const limitsStart = source.indexOf('class XiaoyiToolLimits');
assert.ok(limitsStart >= 0, 'could not find XiaoyiToolLimits');
const limitsEnd = source.indexOf('\n}', limitsStart);
const limits = source.slice(limitsStart, limitsEnd + 2);

const code = transformSync(`${limits}\n${methods}`, { loader: 'ts', format: 'cjs' }).code +
  `\nmodule.exports = { XiaoyiToolLimits, ${names.join(', ')} };`;
const module = { exports: {} };
const compareVaultNames = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
vm.runInContext(code, vm.createContext({ module, exports: module.exports, Error, Date, compareVaultNames }));
const { parseLimit, parseOffset, parseCursor, encodeCursor, buildSnippet, lineOfOffset, buildOutline,
  planChunk, collectTreeEntries, withinDepth, relativeDepth, countNotesUnder, inFolder, lastSegment,
  isoDate, outputChars, fitJsonArrayCount, fitChunkToOutputBudget, parseReadOnlyFolders, isReadOnlyPath,
  fitPage, ensureOutputBudget, XiaoyiToolLimits } = module.exports;

/** vm realm 产出的数组与宿主数组结构相同但引用不等，比较前先做一次 JSON 往返。 */
const plain = (value) => JSON.parse(JSON.stringify(value));

// 分页与游标
assert.equal(parseLimit(undefined, 8, 20, 'limit'), 8);
assert.equal(parseLimit('3', 8, 20, 'limit'), 3);
assert.equal(parseLimit(' 12 ', 8, 20, 'limit'), 12);
assert.throws(() => parseLimit('0', 8, 20, 'limit'), /INVALID_ARGUMENT/);
assert.throws(() => parseLimit('x', 8, 20, 'limit'), /INVALID_ARGUMENT/);
assert.throws(() => parseLimit('21', 8, 20, 'limit'), /LIMIT_EXCEEDED/);
assert.equal(parseOffset(undefined), 0);
assert.equal(parseOffset(''), 0);
assert.equal(parseOffset('24'), 24);
assert.throws(() => parseOffset('-1'), /INVALID_ARGUMENT/);
assert.equal(parseCursor(undefined), 0);
assert.equal(parseCursor(''), 0);
assert.equal(parseCursor(encodeCursor(11)), 11);
assert.throws(() => parseCursor('nonsense'), /INVALID_ARGUMENT/);
assert.throws(() => parseCursor('xyo!!'), /INVALID_ARGUMENT/);

// 片段：命中词不被截断
const long = `${'甲'.repeat(200)}关键词${'乙'.repeat(200)}`;
const snippet = buildSnippet(long, 200, 3);
assert.ok(snippet.includes('关键词'), 'snippet must keep the matched term');
assert.ok(snippet.length <= 165, `snippet too long: ${snippet.length}`);
assert.ok(snippet.startsWith('…') && snippet.endsWith('…'), 'both sides must be marked as trimmed');
assert.equal(buildSnippet('短文本', 0, 2), '短文本');
assert.equal(buildSnippet('短文本', -1, 2), '');

// 行号
assert.equal(lineOfOffset('a\nb\nc', 0), 1);
assert.equal(lineOfOffset('a\nb\nc', 3), 2);
assert.equal(lineOfOffset('a\nb\nc', 99), 3);

// 大纲：frontmatter 与围栏内的标题不计数
const markdown = ['---', 'title: 笔记', '---', '# 一级', '正文', '```', '# 代码里的井号', '```', '## 二级'].join('\n');
const outline = buildOutline(markdown);
assert.deepEqual(plain(outline.map((item) => item.title)), ['一级', '二级']);
assert.deepEqual(plain(outline.map((item) => item.level)), [1, 2]);
assert.equal(outline[1].offset, markdown.indexOf('## 二级'));

// 分段：换行对齐、末尾、代理对保护
const doc = `${'第一行内容\n'.repeat(3)}结尾`;
const first = planChunk(doc, 0, 12);
assert.equal(first.end, 12, 'chunk end must align to a line break');
assert.equal(doc.substring(first.start, first.end), '第一行内容\n第一行内容\n');
assert.equal(first.hasMore, true);
assert.equal(planChunk(doc, 3, 12).end, 12, 'a chunk started mid-line still ends on a line break');
const tail = planChunk(doc, 18, 12);
assert.equal(tail.hasMore, false);
assert.equal(doc.substring(tail.start, tail.end), '结尾');
const emoji = '😀abc';
assert.equal(planChunk(emoji, 1, 10).start, 0, 'offset inside a surrogate pair must step back');
assert.equal(planChunk(doc, 999, 10).start, doc.length);
const emojiChunk = planChunk('ab😀cd', 0, 3);
assert.equal(emojiChunk.end, 2, 'chunk end must not split a surrogate pair');
assert.equal('ab😀cd'.substring(emojiChunk.start, emojiChunk.end) +
  'ab😀cd'.substring(emojiChunk.end), 'ab😀cd', 'surrogate-safe chunks must concatenate exactly');

// 输出预算按所有字符串字段的 UTF-16 长度计算
assert.equal(XiaoyiToolLimits.outputBudgetChars, 6000);
assert.equal(outputChars({ content: '中文😀', hitsJson: '[{"title":"标题"}]', count: 2 }),
  '中文😀'.length + '[{"title":"标题"}]'.length);
assert.equal(ensureOutputBudget({ message: 'm'.repeat(XiaoyiToolLimits.outputBudgetChars) }), undefined);
assert.throws(() => ensureOutputBudget({ message: 'm'.repeat(XiaoyiToolLimits.outputBudgetChars + 1) }),
  /OUTPUT_BUDGET_EXCEEDED/);
const outputItems = [{ path: 'a' }, { path: 'bb' }, { path: 'ccc' }];
const twoItemsChars = JSON.stringify(outputItems.slice(0, 2)).length;
assert.equal(fitJsonArrayCount(outputItems, twoItemsChars), 2);
assert.equal(fitJsonArrayCount(outputItems, twoItemsChars - 1), 1);
const secondPage = fitPage(outputItems, 1, 1, 100, 100);
assert.deepEqual(plain(secondPage.items), [{ path: 'bb' }]);
assert.equal(secondPage.nextIndex, 2);
assert.equal(secondPage.skippedCount, 0);
const lastPage = fitPage([{ path: 'last' }], 0, 1, 100, 100);
assert.equal(lastPage.nextIndex, 1, 'the last page must leave no further item');
assert.equal(lastPage.skippedCount, 0);
const emptyPage = fitPage([], 0, 1, 100, 100);
assert.deepEqual(plain(emptyPage.items), []);
assert.equal(emptyPage.nextIndex, 0);
assert.equal(emptyPage.skippedCount, 0);
const oversizedPage = fitPage([{ title: 'x'.repeat(100) }], 0, 1, 10, 10);
assert.deepEqual(plain(oversizedPage.items), []);
assert.equal(oversizedPage.nextIndex, 1, 'an unreturnable item must not trap the cursor');
assert.equal(oversizedPage.skippedCount, 1, 'an unreturnable item must be reported as skipped');
const resumedAfterSkip = fitPage([{ title: 'x'.repeat(100) }, { title: 'next' }],
  oversizedPage.nextIndex, 1, 100, 100);
assert.deepEqual(plain(resumedAfterSkip.items), [{ title: 'next' }]);
assert.equal(resumedAfterSkip.nextIndex, 2);
const deferredPage = fitPage([{ title: 'short' }], 0, 1, 2, 100);
assert.equal(deferredPage.nextIndex, 0,
  'an item that fits the full response budget must not be skipped due to another page consuming space');
const budgetClippedPage = fitPage(outputItems, 0, outputItems.length, twoItemsChars - 1,
  twoItemsChars - 1);
assert.deepEqual(plain(budgetClippedPage.items), outputItems.slice(0, 1));
assert.equal(budgetClippedPage.nextIndex, 1, 'budget clipping must resume at the first unreturned item');
const budgetedContent = '段'.repeat(7000);
const budgetedPlan = fitChunkToOutputBudget(budgetedContent, 0, 8000, 10);
assert.equal(budgetedPlan.end - budgetedPlan.start, XiaoyiToolLimits.outputBudgetChars - 10);
assert.equal(outputChars({
  metadata: 'm'.repeat(10),
  content: budgetedContent.substring(budgetedPlan.start, budgetedPlan.end)
}), XiaoyiToolLimits.outputBudgetChars, 'the exact output budget boundary must be retained');
assert.equal(fitChunkToOutputBudget('abc', 0, 3, 5997).end, 3,
  'a response exactly at the budget must not be shortened');
assert.ok(source.includes('outputChars(result) > XiaoyiToolLimits.outputBudgetChars'),
  'read-only tools must enforce the shared output budget');

// 目录浏览
const dirs = ['工作', '工作/周报', '工作/周报/归档'];
const notes = ['工作/计划.md', '工作/周报/第一篇.md', '工作/周报/归档/旧的.md', '收件箱.md'];
const shallow = collectTreeEntries(dirs, notes, '', 1);
assert.deepEqual(plain(shallow.map((entry) => entry.path)), ['工作', '收件箱.md']);
assert.deepEqual(plain(shallow.map((entry) => entry.type)), ['dir', 'note']);
assert.equal(shallow[0].childCount, 3);
assert.equal(shallow[0].name, '工作');
assert.equal(shallow[1].childCount, 0);
const deep = collectTreeEntries(dirs, notes, '', 2);
assert.deepEqual(plain(deep.map((entry) => entry.path)), ['工作', '工作/周报', '工作/计划.md', '收件箱.md']);
assert.deepEqual(plain(deep.map((entry) => entry.depth)), [1, 2, 2, 1]);
const scoped = collectTreeEntries(dirs, notes, '工作', 1);
assert.deepEqual(plain(scoped.map((entry) => entry.path)), ['工作/周报', '工作/计划.md']);
assert.deepEqual(plain(scoped.map((entry) => entry.depth)), [1, 1]);
assert.equal(withinDepth('工作/周报', '工作/', 1), true);
assert.equal(withinDepth('工作/周报/归档', '工作/', 1), false);
assert.equal(withinDepth('工作/周报/归档', '工作/', 2), true);
assert.equal(relativeDepth('工作/周报/归档', '工作/'), 2);
assert.equal(countNotesUnder(notes, '工作/周报'), 2);
assert.deepEqual(plain(inFolder(notes, '工作/周报')), ['工作/周报/第一篇.md', '工作/周报/归档/旧的.md']);
assert.deepEqual(plain(inFolder(notes, '')), notes);
assert.equal(lastSegment('工作/计划.md'), '计划.md');
assert.equal(isoDate(0), '1970-01-01');

// Wiki rules: strict inline-list parsing, path-boundary matching, and fail-closed invalid config
const wikiRules = '\uFEFF---\r\ntitle: Wiki\r\nreadonly: ["raw/", "资料/原始"]\r\n---\r\n正文';
assert.deepEqual(plain(parseReadOnlyFolders(wikiRules)), ['raw', '资料/原始']);
assert.deepEqual(plain(parseReadOnlyFolders('# no frontmatter')), []);
assert.equal(isReadOnlyPath('raw/source.md', 'raw'), true);
assert.equal(isReadOnlyPath('raw', 'raw'), true);
assert.equal(isReadOnlyPath('raw-material/source.md', 'raw'), false);
assert.throws(() => parseReadOnlyFolders('---\nreadonly: ["raw/"]'), /WIKI_RULE_INVALID/);
assert.throws(() => parseReadOnlyFolders('---\nreadonly: ["../raw/"]\n---'), /WIKI_RULE_INVALID/);
assert.throws(() => parseReadOnlyFolders('---\nreadonly: ["raw/"]\nreadonly: []\n---'), /WIKI_RULE_INVALID/);
assert.throws(() => parseReadOnlyFolders('---\nreadonly: raw/\n---'), /WIKI_RULE_INVALID/);

// 源码接线：新只读工具已路由，但不在平台意图清单里（绑定不在本版范围）
const executor = fs.readFileSync(new URL('../../entry/src/main/ets/entryability/InsightIntentExecutorImpl.ets',
  import.meta.url), 'utf8');
const profile = JSON.parse(fs.readFileSync(new URL('../../entry/src/main/resources/base/profile/insight_intent.json',
  import.meta.url), 'utf8'));
for (const name of ['SearchNotes', 'ListTree', 'GetLinks']) {
  assert.ok(source.includes(`name === '${name}'`), `${name} must be dispatched by the note service`);
  assert.ok(executor.includes(`'${name}'`), `${name} must be routed by the executor`);
  assert.ok(!profile.insightIntents.some((intent) => intent.intentName === name),
    `${name} must not be registered as a platform intent in this release`);
}
for (const method of ['searchNotes', 'listTree', 'getLinks']) {
  const start = source.search(new RegExp(`private (?:async )?${method}\\(`));
  assert.ok(start >= 0, `missing ${method}`);
  assert.ok(source.slice(start, start + 300).includes('InsightIntentNoteService.resolveVaultId(params, this.registry.currentId())'),
    `${method} must resolve vaultId with an explicit-current fallback`);
}
assert.ok(source.includes('const segmented: boolean ='), 'ReadNote must keep whole-note output when no chunk is requested');
assert.ok(source.includes('result[\'contentHash\'] = AgentOperationStorage.hashText(content)'),
  'baseHash must stay a whole-note hash even for a chunk');
assert.ok(source.includes('private requireAgentWritablePath('), 'AI writes must enforce Wiki read-only rules');
assert.ok(source.includes("if (path === '_wiki.md')"), '_wiki.md must remain read-only to the agent');
const readNoteStart = source.indexOf('private readNote(');
const readNoteEnd = source.indexOf('\n  private ', readNoteStart + 8);
const readNoteBody = source.slice(readNoteStart, readNoteEnd);
assert.ok(readNoteBody.includes("parseCursor(params['cursor'])"), 'outline paging must use its own cursor');
assert.ok(readNoteBody.includes("result['nextCursor']"), 'outline paging must return nextCursor');
assert.ok(readNoteBody.includes("result['total']"), 'outline paging must return total heading count');
assert.ok(readNoteBody.includes("result['skippedCount']"), 'outline paging must report oversized skipped headings');
const linksStart = source.indexOf('private async getLinks(');
const linksEnd = source.indexOf('\n  private ', linksStart + 8);
const linksBody = source.slice(linksStart, linksEnd);
for (const field of ['outCursor', 'inCursor', 'outNextCursor', 'inNextCursor', 'outSkipped', 'inSkipped']) {
  assert.ok(linksBody.includes(field), `GetLinks must support independent ${field}`);
}
for (const method of ['createNote', 'appendNote', 'editNote', 'applyExistingMutation']) {
  const start = source.search(new RegExp(`private (?:async )?${method}\\(`));
  assert.ok(start >= 0, `missing ${method}`);
  const end = source.indexOf('\n  private ', start + 8);
  const body = source.slice(start, end < 0 ? source.length : end);
  assert.ok(body.includes('this.requireAgentWritablePath(vaultId,'), `${method} must enforce Wiki write rules`);
}
for (const method of ['queryNotes', 'readNote', 'searchNotes', 'listTree', 'getLinks']) {
  const start = source.search(new RegExp(`private (?:async )?${method}\\(`));
  assert.ok(start >= 0, `missing ${method}`);
  const end = source.indexOf('\n  private ', start + 8);
  const body = source.slice(start, end < 0 ? source.length : end);
  assert.ok(body.includes('ensureOutputBudget(result)'), `${method} must enforce the final output budget`);
}
assert.ok(!source.includes('hilog'), 'note content must never reach logs');
assert.ok(!source.includes('console.'), 'note content must never reach logs');

console.log('v1.16 只读导航工具分页、分段、大纲、目录与链接接线检查通过（不代表平台调用或设备验收）');
