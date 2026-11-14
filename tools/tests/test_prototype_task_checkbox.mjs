import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readSourceFile } from './lib/source.mjs';

const html = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));
const checklist = readSourceFile(new URL('../../sample_vault/notes/10_写作/任务清单.md', import.meta.url));

function extractFunction(name) {
  const match = html.match(new RegExp('^function ' + name + '\\([^\\n]*$', 'm'));
  assert.ok(match, `prototype must define ${name}`);
  return match[0];
}

function createHarness() {
  const notes = { todo: { text: '' } };
  const history = [];
  const changed = [];
  const toasts = [];
  const context = {
    inline: (text) => text,
    note: (id) => notes[id],
    simpleNoteId: () => 'todo',
    simpleRecord: (id, before) => history.push(before),
    simpleChanged: (id, pane) => changed.push([id, pane]),
    toast: (message) => toasts.push(message)
  };
  vm.createContext(context);
  vm.runInContext(
    extractFunction('simpleTaskCheckbox') + '\n' + extractFunction('syncSimpleTaskBox'),
    context
  );
  return { context, notes, history, changed, toasts };
}

function taskLines(text) {
  const lines = [];
  let offset = 0;
  for (const match of text.matchAll(/[^\r\n]*(?:\r\n|\n|\r|$)/g)) {
    const raw = match[0];
    if (!raw && match.index === text.length) break;
    lines.push({ text: raw.replace(/(?:\r\n|\n|\r)$/, ''), start: offset });
    offset += raw.length;
  }
  return lines;
}

function makeBox(from, checked) {
  return {
    disabled: false,
    checked,
    dataset: { taskFrom: String(from) },
    attributes: {},
    setAttribute(key, value) { this.attributes[key] = value; }
  };
}

test('v2 原型把任务复选框渲染成带源码偏移的可交互控件，不再写死只读', () => {
  assert.match(html, /\(task\?simpleTaskCheckbox\(item\.start,listMatch,task,n\)/);
  assert.match(html, /function simpleTaskCheckbox\(/);
  assert.match(html, /data-simple-task="true"/);
  assert.match(html, /data-task-from="'\+from\+'"/);
  assert.match(html, /aria-label="任务状态"/);
  assert.doesNotMatch(html, /<input type="checkbox" disabled aria-label="任务状态"/);

  // 渲染默认只读，简单模式由 prepareSimpleBlocks 解除；专业模式切走时重新禁用。
  assert.match(html, /box\.disabled=!taskEnabled/);
  assert.match(html, /const taskEnabled=experience==='simple'&&!!id/);
  assert.match(html, /for\(const el of root\.querySelectorAll\('input\[data-simple-task\]'\)\)\{el\.disabled=true/);

  // 点击接线必须在复杂块 hit 判定之前，否则 .cb-para 会抢走点击去开面板。
  const clickIndex = html.indexOf("const taskBox=tgt.closest('input[data-simple-task]')");
  const hitIndex = html.indexOf("const hit=tgt.closest('.md-unknown-colon')");
  assert.ok(clickIndex > 0 && hitIndex > clickIndex, 'task checkbox click must be handled before complex block hit');
  const clickLine = html.split('\n').find((line) => line.includes("const taskBox=tgt.closest('input[data-simple-task]')")) ?? '';
  // 复选框落在可编辑 <li> 内：真实浏览器里 onmousedown 会被可编辑容器吞掉光标，
  // 且原生 checkbox 默认动作会在捕获阶段之后把 box.checked 再翻一次（双翻转抵消 → 源码跳了、
  // 框视觉不动，表现为「点不动」）。所以点击处理只 early-return 放行原生（视觉由原生负责），
  // 由 change 事件在原生翻完之后把源码落盘；绝不能 preventDefault，也不能在捕获阶段手动翻。
  assert.match(clickLine, /taskBox&&!taskBox\.disabled&&root\.contains\(taskBox\)\)\{return;\}/, 'checkbox click must be released to native + change handler');
  assert.doesNotMatch(clickLine, /toggleSimpleTaskBox/, 'checkbox must NOT be toggled inside the click handler (native owns the visual)');
  assert.doesNotMatch(clickLine, /preventDefault/, 'must not cancel the native checkbox activation');
  assert.match(html, /addEventListener\('change',event=>\{[^}]*syncSimpleTaskBox/, 'a change listener must persist the toggle after native activation');
});

test('复选框焦点不算「编辑文字」：否则格式栏插入正文流把框顶走，点击永远丢失', () => {
  // 真浏览器（CDP 真实鼠标）验证过的失效链：
  // mousedown 命中 INPUT → focusin → leftPane 加 text-focus → 格式栏占位把正文下移 57px
  // → mouseup 落到 ARTICLE → click 派发给共同祖先 → 复选框收不到 click，源码与勾选都不变。
  // 而抬手点在空白处又让 input 失焦、布局弹回，下次点击重演 —— 所以必须有两道守卫。
  assert.match(
    html,
    /if\(a\.matches&&a\.matches\('input\[data-simple-task\]'\)\)return false;/,
    'paneHasTextFocus must not treat a task checkbox as text editing focus'
  );
  const mousedownLine = html.split('\n').find((line) => line.includes("root.addEventListener('mousedown'")) ?? '';
  assert.match(mousedownLine, /event\.target\.closest\('input\[data-simple-task\]'\)/);
  assert.match(mousedownLine, /event\.preventDefault\(\)/, 'task checkbox must not take focus on mousedown');

  // 行为级：祖先 <li contenteditable=true> 时旧实现返回 true（正是布局位移的来源）。
  const paneRoot = { contains: () => true };
  const context = { document: { activeElement: null }, $: () => paneRoot };
  vm.createContext(context);
  vm.runInContext(extractFunction('paneHasTextFocus'), context);
  context.document.activeElement = {
    matches: (selector) => selector === 'input[data-simple-task]',
    closest: (selector) => (selector === '[contenteditable=true]' ? {} : null)
  };
  assert.equal(context.paneHasTextFocus('left'), false, 'task checkbox focus must not enable the text-focus layout');
  context.document.activeElement = {
    matches: () => false,
    closest: (selector) => (selector === '[contenteditable=true]' ? {} : null)
  };
  assert.equal(context.paneHasTextFocus('left'), true, 'real text editing still shows the format bar');
  context.document.activeElement = { matches: () => false, closest: () => null };
  assert.equal(context.paneHasTextFocus('left'), false, 'focus outside the pane is not text focus');
});

test('渲染偏移命中 sample_vault 任务清单的真实源码（防止三方区间口径漂移）', () => {
  const { context } = createHarness();
  let count = 0;
  for (const item of taskLines(checklist)) {
    const listMatch = item.text.match(/^(\s*)([-*+]|\d+[.)]) (.*)$/);
    if (!listMatch) continue;
    const task = listMatch[3].match(/^\[([ xX])\] (.*)$/);
    if (!task) continue;
    const output = context.simpleTaskCheckbox(item.start, listMatch, task, { text: checklist });
    const from = Number(/data-task-from="(\d+)"/.exec(output)[1]);
    assert.equal(checklist.slice(from, from + 3), '[' + task[1] + ']',
      `task checkbox offset must land on the source marker at line ${item.start}`);
    assert.match(output, /data-simple-task="true"/);
    // 复选框必须是 contenteditable="false" 岛屿：否则身处可编辑 <li> 内时，真实浏览器的
    // onmousedown 会被可编辑容器吞掉，checkbox 收不到点击 → 点不动。
    assert.match(output, /contenteditable="false"/, `task checkbox must be a non-editable island (line ${item.start})`);
    count++;
  }
  assert.equal(count, 4, 'sample vault checklist carries four task markers');
  assert.ok(checklist.includes('[x]') && checklist.includes('[ ]'), 'fixture covers both states');
});

test('复选框原生 toggle 后由 change 落盘源码：等长替换、可撤销、同步 DOM', () => {
  const { context, notes, history, changed } = createHarness();
  const root = { id: 'article' };
  // syncSimpleTaskBox 读取的是原生已经翻好的 box.checked（新状态），再把源码对齐
  const persist = (text, from, checked) => {
    notes.todo.text = text;
    const box = makeBox(from, checked);
    context.syncSimpleTaskBox(box, root);
    return { text: notes.todo.text, box };
  };

  let result = persist('- [ ] 买牛奶', 2, true);
  assert.equal(result.text, '- [x] 买牛奶');
  assert.equal(result.text.length, '- [ ] 买牛奶'.length, 'replacement must keep every later source offset');
  assert.equal(result.box.checked, true, 'box.checked 由原生负责，函数不应改动');
  assert.equal(result.box.attributes['aria-checked'], 'true');

  result = persist('- [x] 买牛奶', 2, false);
  assert.equal(result.text, '- [ ] 买牛奶');
  assert.equal(result.box.checked, false);
  assert.equal(result.box.attributes['aria-checked'], 'false');

  result = persist('  3. [X] 深层任务', 5, false);
  assert.equal(result.text, '  3. [ ] 深层任务');
  assert.equal(result.box.checked, false);

  assert.equal(history.length, 3, 'every toggle records one undo step');
  assert.equal(changed.length, 3, 'every toggle notifies the editor / other pane');
  assert.deepEqual(changed[0], ['todo', 'left']);
});

test('源码已变或区间无复选框时拒绝误改', () => {
  const { context, notes, history, toasts } = createHarness();
  notes.todo.text = '- 普通列表';
  const box = makeBox(2, false);
  context.syncSimpleTaskBox(box, { id: 'article' });
  assert.equal(notes.todo.text, '- 普通列表');
  assert.equal(box.checked, false);
  assert.equal(history.length, 0);
  assert.equal(toasts.length, 1);

  notes.todo.text = '- [ ] 买牛奶';
  const disabled = makeBox(2, false);
  disabled.disabled = true;
  context.syncSimpleTaskBox(disabled, { id: 'article' });
  assert.equal(notes.todo.text, '- [ ] 买牛奶', 'professional mode / preview checkboxes stay read-only');
});

test('设计稿内嵌样例数据与 sample_vault 同源', () => {
  const begin = html.indexOf('SAMPLE_VAULT_V2_BEGIN');
  const end = html.indexOf('SAMPLE_VAULT_V2_END');
  assert.ok(begin > 0 && end > begin);
  const block = html.slice(begin, end);
  assert.match(block, /generated by tools\/generators\/build_sample_vault\.py/);
  assert.match(block, /"title":\s*"任务清单"/);
  assert.ok(block.includes('打开样例库'), 'generated data must reuse the vault markdown verbatim');
});
