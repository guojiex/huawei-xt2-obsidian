import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const script = html.split('/* AGENT_DESIGN_BEGIN:')[1].split('/* AGENT_DESIGN_END */')[0];
const code = script.slice(script.indexOf('var agentStores'));
const builtins = html.match(/\/\* AGENT_PROMPT_BEGIN:[\s\S]*?\*\/([\s\S]*?)\/\* AGENT_PROMPT_END \*\//)[1];
const configCode = html.split('/* AGENT_CONFIG_BEGIN */')[1].split('/* AGENT_CONFIG_END */')[0];
function fixture({ storageFails = false } = {}) {
  const storage = new Map();
  const nodes = new Map();
  const get = (id) => {
    if (!nodes.has(id)) {
      const attrs = {}, classes = new Set();
      nodes.set(id, { value: '', innerHTML: '', textContent: '', handlers: {}, scrollTop: 0,
        classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c), toggle: (c, force) => { if (force === undefined ? !classes.has(c) : force) classes.add(c); else classes.delete(c); } },
        addEventListener(type, fn) { this.handlers[type] = fn; },
        setAttribute(k, v) { attrs[k] = v; }, getAttribute(k) { return attrs[k]; }, focus() {}, contains() { return false; }
      });
    }
    return nodes.get(id);
  };
  const c = vm.createContext({ localStorage: { getItem: k => storage.get(k) || null, setItem(k,v) { if (storageFails) throw new Error('blocked'); storage.set(k,v); } }, document: { getElementById: get },
    currentVault: 'local', current: 'reading_journal', CONTENT: { reading_journal: '# 阅读\n我的理解', other: '# 另一库' },
    FILES: { reading_journal: '阅读.md', other: '另一库.md' }, META: {},
    TREES: { local: [['file', '阅读.md', false, 0, 'reading_journal']], otherVault: [['file', '另一库.md', false, 0, 'other']] },
    VAULTS: [{ id: 'local', name: '本地笔记', files: 1 }, { id: 'otherVault', name: '其他库', files: 1 }],
    body: { getAttribute() { return 'lg'; } }, ta: { value: '# 阅读\n我的理解', scrollTop: 0 },
    esc: (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
    renderTree() {}, updateVaultUI() {}, setView() {}
  });
  vm.runInContext(`function currentFileRows() { return TREES[currentVault].filter(r => r[0] === 'file').map(r => ({id:r[4],name:r[1],path:r[1]})); }
    function vaultById(id) { return VAULTS.find(v => v.id === id); }
    function loadFile() { ta.value = CONTENT[current] || ''; }
    function switchVault(id) { currentVault = id; current = TREES[id][0][4]; loadFile(); }`, c);
  vm.runInContext(builtins + configCode, c);
  vm.runInContext(code, c);
  return { c, get, storage, run: (s) => vm.runInContext(s, c) };
}

test('prototype controls have unique IDs and agent DOM references resolve', () => {
  const ids = [...html.split('<script>')[0].matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const [, id] of code.matchAll(/ag\('([^']+)'\)/g)) assert.ok(ids.includes(id), id);
});
test('conversation is preloaded with original reading prompts and source snapshots', () => {
  const f = fixture(); f.run('renderAgent()');
  assert.equal(f.run('agentSession().messages.length'), 2);
  assert.equal(f.run('agentSession().messages[0].refs[0].content'), '# 阅读\n我的理解');
  assert.match(f.get('agentMessages').innerHTML, /固定 mock/);
});
test('drag/click reference semantics deduplicate and reject another vault', () => {
  const f = fixture(); f.run("agentAddRef('local','reading_journal'); agentAddRef('local','reading_journal'); agentAddRef('otherVault','other')");
  assert.equal(f.run('agentSession().refs.length'), 1);
  assert.match(f.get('agentStatus').textContent, /只能引用/);
});
test('send captures references, clears composer and preserves multi-turn messages', () => {
  const f = fixture(); f.run("agentAddRef('local','reading_journal')"); f.get('agentInput').value = '请追问我'; f.run('agentSend()');
  assert.equal(f.run('agentSession().messages.length'), 4);
  assert.equal(f.run('agentSession().messages[2].refs[0].content'), '# 阅读\n我的理解');
  assert.equal(f.run('agentSession().refs.length'), 0); assert.equal(f.get('agentInput').value, '');
});
test('direct append displays before/after and undo restores exact original', () => {
  const f = fixture(); f.run("agentWrite('append', 1)");
  assert.match(f.c.CONTENT.reading_journal, /对话沉淀/);
  assert.equal(f.run('agentSession().messages[1].result.before'), '# 阅读\n我的理解');
  f.run('agentUndo(1)'); assert.equal(f.c.CONTENT.reading_journal, '# 阅读\n我的理解');
});
test('changed or unsaved note blocks stale writes without losing edits', () => {
  const f = fixture(); f.run('renderAgent()'); f.c.CONTENT.reading_journal = '后续编辑'; f.c.ta.value = '后续编辑';
  assert.throws(() => f.run("agentWrite('append',1)"), /变化/);
  assert.equal(f.c.CONTENT.reading_journal, '后续编辑');
  const g = fixture(); g.c.ta.value = '未保存内容';
  assert.throws(() => g.run("agentWrite('append',1)"), /未保存/);
});
test('undo refuses later content changes and earlier operations', () => {
  const f = fixture(); f.run("agentWrite('append',1)"); f.c.CONTENT.reading_journal += '\n手动修改';
  assert.throws(() => f.run('agentUndo(1)'), /后续修改/);
  assert.match(f.c.CONTENT.reading_journal, /手动修改/);
});
test('new-note undo removes only the created file and does not clobber names', () => {
  const f = fixture(); f.run("agentWrite('create',1)"); const id = f.run('agentLastWrite.id');
  assert.equal(f.c.FILES[id], '读书对话沉淀.md'); f.run('agentUndo(1)');
  assert.equal(f.c.FILES[id], undefined); assert.equal(f.c.CONTENT.reading_journal, '# 阅读\n我的理解');
});
test('switching vaults isolates histories, draft references, and eligible sources', () => {
  const f = fixture(); f.run("agentAddRef('local','reading_journal'); agentSession().draft='未发送问题'; switchVault('otherVault'); renderAgent()");
  assert.equal(f.run('agentSession().refs.length'), 0); assert.equal(f.get('agentInput').value, '');
  assert.equal(f.run('agentSession().messages[0].refs.length'), 0);
  f.run("switchVault('local'); renderAgent()"); assert.equal(f.get('agentInput').value, '未发送问题');
  assert.equal(f.run('agentSession().refs.length'), 1);
});
test('Chinese composition Enter does not send, regular Enter sends', () => {
  const f = fixture(); f.run('renderAgent()'); f.get('agentInput').value = '理解';
  let prevented = false;
  f.get('agentInput').handlers.keydown({ key: 'Enter', isComposing: true, preventDefault() { prevented = true; } });
  assert.equal(f.run('agentSession().messages.length'), 2); assert.equal(prevented, false);
  f.get('agentInput').handlers.keydown({ key: 'Enter', isComposing: false, preventDefault() { prevented = true; } });
  assert.equal(f.run('agentSession().messages.length'), 4); assert.equal(prevented, true);
});


test('mock scenarios return different fixed replies and unmatched input never writes', () => {
  const f = fixture(); f.get('agentInput').value = '开始读书讨论'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'), /读到哪里/);
  f.get('agentInput').value = '整理讨论要点'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'), /四点沉淀/);
  const before = JSON.stringify(f.c.CONTENT); f.get('agentInput').value = '随便写一些未支持的问题'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'), /未命中/); assert.equal(JSON.stringify(f.c.CONTENT), before);
});
test('scripted read then append invokes tools and exposes actual results', () => {
  const f = fixture(); f.run("agentAddRef('local','reading_journal')");
  f.get('agentInput').value = '把这轮结论追加到笔记'; f.run('agentSend()');
  assert.equal(f.run('agentSession().messages.at(-1).trace.length'), 2);
  assert.equal(f.run('agentSession().messages.at(-1).trace[1].status'), 'completed');
  assert.match(f.c.CONTENT.reading_journal, /阅读后的自检/);
  f.get('agentInput').value = '撤销上次修改'; f.run('agentSend()');
  assert.equal(f.c.CONTENT.reading_journal, '# 阅读\n我的理解');
});
test('disabled tool is rejected by scripts and manual result-card actions', () => {
  const f = fixture(); f.run("agentConfig.enabledTools = ['ReadNote','UndoLastEdit']; agentAddRef('local','reading_journal')");
  const before = f.c.CONTENT.reading_journal; f.get('agentInput').value = '把这轮结论追加到笔记'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'), /TOOL_DISABLED/);
  assert.equal(f.c.CONTENT.reading_journal, before);
  assert.throws(() => f.run("agentWrite('create',1)"), /TOOL_DISABLED/);
});
test('skill tool restriction is enforced even if the global tool is enabled', () => {
  const f = fixture(); f.run("agentSession().skillId='synthesis'; agentAddRef('local','reading_journal')");
  f.get('agentInput').value = '把熟悉改成理解'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'), /TOOL_DISABLED/);
  assert.equal(f.c.CONTENT.reading_journal, '# 阅读\n我的理解');
});
test('prompt save persists next-run config while previous snapshot stays immutable', () => {
  const f = fixture(); f.run("var oldConfig=agentRunConfig('reading')");
  f.get('configSystemPrompt').value = '自定义阅读风格'; f.get('configSavePrompt').handlers.click();
  assert.equal(f.run('agentRunConfig("reading").prompt'), '自定义阅读风格');
  assert.notEqual(f.run('oldConfig.prompt'), '自定义阅读风格'); assert.equal(f.storage.size, 1);
  f.get('configResetPrompt').handlers.click();
  assert.equal(f.run('agentConfig.systemPrompt'), f.run('BUILTIN_AGENT_PROMPT.text'));
});
test('storage failure and empty prompt do not replace the active config', () => {
  const f = fixture({storageFails:true}); const before = f.run('agentConfig.systemPrompt');
  f.get('configSystemPrompt').value = '新内容'; f.get('configSavePrompt').handlers.click();
  assert.equal(f.run('agentConfig.systemPrompt'), before); assert.match(f.get('agentConfigStatus').textContent,/保存失败/);
  f.get('configSystemPrompt').value = '  '; f.get('configSavePrompt').handlers.click();
  assert.match(f.get('agentConfigStatus').textContent,/不能为空/);
});
test('settings tabs retain prompt drafts and keyboard navigation selects a panel', () => {
  const f = fixture(); f.get('configSystemPrompt').value = '未保存草稿';
  f.run("setSettingsTab('data'); setSettingsTab('agent')"); assert.equal(f.get('configSystemPrompt').value, '未保存草稿');
  f.get('settings-tab-agent').handlers.keydown({key:'ArrowRight',preventDefault(){}});
  assert.equal(f.run('settingsTab'), 'data');
  assert.equal(f.get('settings-tab-data').getAttribute('aria-selected'), 'true');
});

test('read and filename query report actual current-library results', () => {
  const f = fixture(); f.run("agentAddRef('local','reading_journal')");
  f.get('agentInput').value = '读取引用笔记'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).trace[0].result'), /我的理解/);
  f.get('agentInput').value = '查找阅读笔记'; f.run('agentSend()');
  assert.equal(f.run('agentSession().messages.at(-1).trace[0].result'), '阅读.md');
});
test('edit uses a unique exact anchor and rejects repeated anchors without a write', () => {
  const f = fixture(); f.c.CONTENT.reading_journal = '熟悉不等于理解'; f.c.ta.value = '熟悉不等于理解';
  f.run("agentAddRef('local','reading_journal')"); f.get('agentInput').value = '把熟悉改成理解'; f.run('agentSend()');
  assert.equal(f.c.CONTENT.reading_journal, '熟悉只是起点，理解还需要例子与反例');
  const g = fixture(); g.c.CONTENT.reading_journal = '熟悉不等于理解；熟悉不等于理解'; g.c.ta.value = g.c.CONTENT.reading_journal;
  g.run("agentAddRef('local','reading_journal')"); g.get('agentInput').value = '把熟悉改成理解'; g.run('agentSend()');
  assert.match(g.run('agentSession().messages.at(-1).text'), /ANCHOR_NOT_UNIQUE/);
  assert.equal(g.c.CONTENT.reading_journal, '熟悉不等于理解；熟悉不等于理解');
});
test('restoring a Skill preserves the system prompt, tools and notes', () => {
  const f = fixture(); f.run("agentConfig.systemPrompt='我的风格'; agentConfig.skillOverrides.reading='我的导读'; agentConfig.enabledTools=['ReadNote','UndoLastEdit']");
  f.get('configSkill').value = 'reading'; f.get('configResetSkill').handlers.click();
  assert.equal(f.run('agentConfig.systemPrompt'), '我的风格');
  assert.equal(f.run('agentConfig.skillOverrides.reading'), undefined);
  assert.equal(f.run('agentConfig.enabledTools.length'), 2);
  assert.equal(f.c.CONTENT.reading_journal, '# 阅读\n我的理解');
});
test('stored configuration cannot add unknown tools or disable recovery', () => {
  const f = fixture();
  assert.equal(f.run("agentNormalizeConfig({version:1,enabledTools:['Shell','ReadNote']}).enabledTools.join(',')"), 'ReadNote,UndoLastEdit');
  assert.equal(f.run("agentNormalizeConfig({version:1,systemPrompt:'  ',promptSource:'custom'}).promptSource"), 'builtin');
});
