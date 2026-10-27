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
        setAttribute(k, v) { attrs[k] = v; }, removeAttribute(k) { delete attrs[k]; }, getAttribute(k) { return attrs[k]; }, focus() {}, select() {}, querySelectorAll() { return []; }, setSelectionRange(start,end) { this.selectionStart=start; this.selectionEnd=end; }, contains() { return false; }
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
    renderTree() {}, updateVaultUI() {}, setView() {}, applySplit() {}, drawHinges() {}
  });
  vm.runInContext(`function currentFileRows() { return TREES[currentVault].filter(r => r[0] === 'file').map(r => ({id:r[4],name:r[1],path:r[1]})); }
    function vaultById(id) { return VAULTS.find(v => v.id === id); }
    function loadFile() { ta.value = CONTENT[current] || ''; }
    function switchVault(id) { currentVault = id; current = TREES[id][0][4]; loadFile(); }`, c);
  vm.runInContext(builtins + configCode, c);
  vm.runInContext(html.slice(html.indexOf('  var IC ='), html.indexOf('  /* ---------- 编辑器 + 高亮 + 预览 ---------- */')), c);
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
  const f = fixture(); f.run("agentAddRef('local','reading_journal')"); f.get('agentInput').value = '[[阅读.md]]请追问我'; f.run('agentSend()');
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
  f.get('agentInput').value = '[[阅读.md]]把这轮结论追加到笔记'; f.run('agentSend()');
  assert.equal(f.run('agentSession().messages.at(-1).trace.length'), 2);
  assert.equal(f.run('agentSession().messages.at(-1).trace[1].status'), 'completed');
  assert.match(f.c.CONTENT.reading_journal, /阅读后的自检/);
  f.get('agentInput').value = '撤销上次修改'; f.run('agentSend()');
  assert.equal(f.c.CONTENT.reading_journal, '# 阅读\n我的理解');
});
test('disabled tool is rejected by scripts and manual result-card actions', () => {
  const f = fixture(); f.run("agentConfig.enabledTools = ['ReadNote','UndoLastEdit']; agentAddRef('local','reading_journal')");
  const before = f.c.CONTENT.reading_journal; f.get('agentInput').value = '[[阅读.md]]把这轮结论追加到笔记'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'), /TOOL_DISABLED/);
  assert.equal(f.c.CONTENT.reading_journal, before);
  assert.throws(() => f.run("agentWrite('create',1)"), /TOOL_DISABLED/);
});
test('skill tool restriction is enforced even if the global tool is enabled', () => {
  const f = fixture(); f.run("agentSession().skillId='synthesis'; agentAddRef('local','reading_journal')");
  f.get('agentInput').value = '[[阅读.md]]把熟悉改成理解'; f.run('agentSend()');
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
  f.run("settingsReturnView = 'agent'; setSettingsTab('data'); setSettingsTab('agent')"); assert.equal(f.get('configSystemPrompt').value, '未保存草稿');
  f.get('settings-tab-agent').handlers.keydown({key:'ArrowRight',preventDefault(){}});
  assert.equal(f.run('settingsTab'), 'data');
  assert.equal(f.get('settings-tab-data').getAttribute('aria-selected'), 'true');
});

test('read and filename query report actual current-library results', () => {
  const f = fixture(); f.run("agentAddRef('local','reading_journal')");
  f.get('agentInput').value = '[[阅读.md]]读取引用笔记'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).trace[0].result'), /我的理解/);
  f.get('agentInput').value = '查找阅读笔记'; f.run('agentSend()');
  assert.equal(f.run('agentSession().messages.at(-1).trace[0].result'), '阅读.md');
});
test('edit uses a unique exact anchor and rejects repeated anchors without a write', () => {
  const f = fixture(); f.c.CONTENT.reading_journal = '熟悉不等于理解'; f.c.ta.value = '熟悉不等于理解';
  f.run("agentAddRef('local','reading_journal')"); f.get('agentInput').value = '[[阅读.md]]把熟悉改成理解'; f.run('agentSend()');
  assert.equal(f.c.CONTENT.reading_journal, '熟悉只是起点，理解还需要例子与反例');
  const g = fixture(); g.c.CONTENT.reading_journal = '熟悉不等于理解；熟悉不等于理解'; g.c.ta.value = g.c.CONTENT.reading_journal;
  g.run("agentAddRef('local','reading_journal')"); g.get('agentInput').value = '[[阅读.md]]把熟悉改成理解'; g.run('agentSend()');
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


test('Agent reuses normal tree rows, hides collapsed children and preserves ancestor paths in search', () => {
  const f = fixture();
  f.c.TREES.local = [['dir','阅读',false,0],['file','阅读.md',false,1,'reading_journal']];
  f.run('renderAgentFiles()'); assert.match(f.get('agentFiles').innerHTML,/node dir/); assert.doesNotMatch(f.get('agentFiles').innerHTML,/data-add-ref/);
  f.get('agentSearch').value='阅读.md'; f.run('renderAgentFiles()');
  assert.match(f.get('agentFiles').innerHTML,/node dir/); assert.match(f.get('agentFiles').innerHTML,/node file/);
  assert.match(f.get('agentFiles').innerHTML,/data-drag-note/); assert.match(f.get('agentFiles').innerHTML,/class="guides"/);
  assert.doesNotMatch(f.get('agentFiles').innerHTML,/sw-btn|row-plus|agent-file"/);
  assert.equal(f.c.TREES.local[0][2], false);
});
test('normal note tree retains its controls while Agent uses reference actions', () => {
  const f = fixture();
  const normal=f.run("nodeHtml(['file','阅读.md',false,0,'reading_journal'],0)");
  const agent=f.run("nodeHtml(['file','阅读.md',false,0,'reading_journal'],0,true)");
  assert.match(normal,/sw-btn/); assert.match(normal,/data-id=/); assert.doesNotMatch(normal,/data-add-ref/);
  assert.match(agent,/data-add-ref/); assert.doesNotMatch(agent,/sw-btn/);
});

test('insert at cursor preserves text before/after and allows repeated source mentions', () => {
  const f = fixture(); f.get('agentInput').value = '先参考，解释原因'; f.get('agentInput').setSelectionRange(3,3);
  f.run("agentAddRef('local','reading_journal')");
  assert.equal(f.get('agentInput').value, '先参考[[阅读.md]]，解释原因');
  assert.equal(f.get('agentInput').selectionStart, '先参考[[阅读.md]]'.length);
  f.run("agentAddRef('local','reading_journal')");
  assert.equal(f.run("agentMessageParts(ag('agentInput').value,true).parts.filter(p=>p.type==='note_ref').length"), 2);
  assert.equal(f.run('agentSession().refs.length'), 1);
});
test('one message preserves A/B/A placement with deduplicated content snapshots', () => {
  const f = fixture(); f.c.TREES.local.push(['file','B.md',false,0,'b']); f.c.FILES.b='B.md'; f.c.CONTENT.b='B 的观点';
  f.get('agentInput').value = '先参考[[阅读.md]]解释观点。再参考[[B.md]]比较分歧，最后回到[[阅读.md]]。'; f.run('agentSend()');
  assert.equal(f.run("agentSession().messages[2].parts.map(p=>p.type==='text'?p.text:p.sourceId).join('|')"), '先参考|reading_journal|解释观点。再参考|b|比较分歧，最后回到|reading_journal|。');
  assert.equal(f.run('agentSession().messages[2].refs.length'), 2);
  assert.equal(f.run('agentSession().messages[3].contextParts.length'), 7);
  const rendered=f.get('agentMessages').innerHTML;
  assert.match(rendered,/先参考<button class="agent-inline-ref"/);
  assert.match(rendered,/解释观点。再参考<button class="agent-inline-ref"/);
});
test('removed or invalid inline references do not silently send draft attachments', () => {
  const f = fixture(); f.get('agentNew').handlers.click(); f.run("agentAddRef('local','reading_journal')");
  f.get('agentInput').value='不引用笔记，只讨论'; f.get('agentInput').handlers.input.call(f.get('agentInput')); f.run('agentSend()');
  assert.equal(f.run('agentSession().messages[0].refs.length'),0);
  const count=f.run('agentSession().messages.length'); f.get('agentInput').value='请看[[已删除.md]]';
  assert.throws(()=>f.run('agentSend()'),/引用不存在/); assert.equal(f.run('agentSession().messages.length'),count);
  assert.equal(f.get('agentInput').value,'请看[[已删除.md]]');
});
test('ambiguous multi-reference write is rejected instead of changing the first note', () => {
  const f = fixture(); f.c.TREES.local.push(['file','B.md',false,0,'b']); f.c.FILES.b='B.md'; f.c.CONTENT.b='B';
  f.get('agentInput').value='[[阅读.md]][[B.md]]把这轮结论追加到笔记'; f.run('agentSend()');
  assert.match(f.run('agentSession().messages.at(-1).text'),/AMBIGUOUS_TARGET/);
  assert.equal(f.c.CONTENT.reading_journal,'# 阅读\n我的理解'); assert.equal(f.c.CONTENT.b,'B');
});

test('conversation and file panels collapse independently with all four combinations', () => {
  const f = fixture(); f.run('renderAgent()');
  assert.equal(f.get('agentNav').classList.contains('hidden'), false);
  f.run("toggleAgentPanel('threads')");
  assert.equal(f.get('agentThreadPane').classList.contains('hidden'), true);
  assert.equal(f.get('agentFilePane').classList.contains('hidden'), false);
  assert.equal(f.get('agentNav').getAttribute('data-tab'), 'files');
  f.run("toggleAgentPanel('files')"); assert.equal(f.get('agentNav').classList.contains('hidden'), true);
  f.run("toggleAgentPanel('threads')");
  assert.equal(f.get('agentNav').classList.contains('hidden'), false);
  assert.equal(f.get('agentFilePane').classList.contains('hidden'), true);
  assert.equal(f.get('agentNav').getAttribute('data-show-threads'), 'true');
});
test('attach restores a collapsed file panel without clearing chat draft', () => {
  const f = fixture(); f.run("toggleAgentPanel('threads'); toggleAgentPanel('files')");
  f.get('agentInput').value = '正在写的消息'; f.get('agentAttach').handlers.click();
  assert.equal(f.get('agentNav').classList.contains('hidden'), false);
  assert.equal(f.get('agentFilePane').classList.contains('hidden'), false);
  assert.equal(f.get('agentThreadPane').classList.contains('hidden'), true);
  assert.equal(f.get('agentInput').value, '正在写的消息');
});

for (const form of ['sm', 'md', 'lg']) test(`${form}: hamburger restores both collapsed panels and toggles the sidebar`, () => {
  const f = fixture(); f.c.body.getAttribute = () => form;
  f.run("agentNav('threads')"); f.get('agentCollapseThreads').handlers.click();
  f.run("agentNav('files')"); f.get('agentCollapseFiles').handlers.click();
  assert.equal(f.get('agentNav').classList.contains('hidden'), true);
  f.run('toggleAgentNavigation()');
  assert.equal(f.get('agentNav').classList.contains('hidden'), false);
  assert.equal(f.get('agentThreadPane').classList.contains('hidden'), false);
  assert.equal(f.get('agentFilePane').classList.contains('hidden'), false);
  assert.equal(f.get('agentNav').classList.contains('open'), true);
  f.run('toggleAgentNavigation()');
  if (form === 'sm') {
    assert.equal(f.get('agentNav').classList.contains('open'), false);
    assert.equal(f.get('agentNav').inert, true);
  } else { assert.equal(f.get('agentNav').classList.contains('hidden'), true); }
});
test('sm: hamburger reopens a dismissed drawer in one click', () => {
  const f = fixture(); f.c.body.getAttribute = () => 'sm';
  f.run("agentNav('threads')"); f.get('agentHideNav').handlers.click();
  f.run('toggleAgentNavigation()');
  assert.equal(f.get('agentNav').classList.contains('open'), true);
  assert.equal(f.run('agentPanels.threads'), true);
});
test('dedicated toolbar buttons switch views without toggling Agent panels', () => {
  const f = fixture(); const views = []; f.c.setView = v => views.push(v);
  f.get('xiaoyiBtn').handlers.click(); f.get('noteModeBtn').handlers.click();
  assert.deepEqual(views, ['agent', 'note']);
  assert.equal(f.run('agentPanels.threads && agentPanels.files'), true);
});

test('shared hamburger routes to the current workspace without changing views', () => {
  const f = fixture(); let view = 'agent', noteToggles = 0;
  f.c.body.getAttribute = key => key === 'data-view' ? view : 'lg';
  f.c.toggleDrawer = () => noteToggles++;
  const handler = html.match(/document.getElementById\('menuBtn'\).addEventListener\('click', function \(\) \{[^\n]+/)[0];
  f.run(handler);
  f.get('menuBtn').handlers.click();
  assert.equal(f.get('agentNav').classList.contains('hidden'), true);
  f.get('menuBtn').handlers.click();
  assert.equal(f.get('agentNav').classList.contains('hidden'), false);
  assert.equal(noteToggles, 0);
  view = 'note'; f.get('menuBtn').handlers.click();
  assert.equal(noteToggles, 1);
});

test('shared settings button selects Agent settings only when entering from Agent', () => {
  const f = fixture(); const views = [], tabs = []; let view = 'agent';
  f.c.body.getAttribute = () => view;
  f.c.setViewBtn = v => views.push(v); f.c.setSettingsTab = tab => tabs.push(tab);
  const handler = html.match(/document.getElementById\('settingsBtn'\).addEventListener\('click', function \(\) \{[\s\S]*?\n  \}\);/)[0];
  f.run(handler); f.get('settingsBtn').handlers.click();
  assert.deepEqual(views, ['settings']); assert.deepEqual(tabs, ['agent']);
  view = 'note'; f.get('settingsBtn').handlers.click();
  assert.deepEqual(views, ['settings', 'settings']); assert.deepEqual(tabs, ['agent']);
  assert.equal(html.includes('id="agentSettings"'), false);
});

test('generated prototype has three local vaults with distinct notes and isolated Agent drafts', () => {
  const f = fixture();
  f.run(html.split('/* SAMPLE_VAULT_BEGIN: generated by tools/build_sample_vault.py */')[1].split('/* SAMPLE_VAULT_END */')[0]);
  f.c.renderVaultMenu = () => {};
  f.run(html.match(/function switchVault\(id\) \{[\s\S]*?\n  \}/)[0]);
  assert.deepEqual(Array.from(f.c.VAULTS, v => v.name), ['本地笔记', '阅读笔记', '项目笔记']);
  const seen = new Set();
  for (const vault of f.c.VAULTS) {
    assert.equal(vault.type, 'local');
    const ids = f.c.TREES[vault.id].filter(r => r[0] === 'file').map(r => r[4]);
    assert.equal(ids.length, vault.files);
    for (const id of ids) { assert.ok(!seen.has(id)); seen.add(id); assert.ok(f.c.CONTENT[id]); }
  }
  const change = id => { f.get('agentVault').value = id; f.get('agentVault').handlers.change.call(f.get('agentVault')); };
  f.get('agentInput').value = '本地库草稿'; change('reading');
  assert.equal(f.get('agentInput').value, '');
  assert.equal(f.run('agentRefAllowed(currentVault, "reading_journal")'), false);
  f.run('agentAddRef(currentVault, "reading_reading_journal")');
  const readingDraft = f.get('agentInput').value;
  change('projects'); assert.equal(f.get('agentInput').value, '');
  assert.equal(f.run('agentRefAllowed(currentVault, "reading_reading_journal")'), false);
  change('reading'); assert.equal(f.get('agentInput').value, readingDraft);
  change('local'); assert.equal(f.get('agentInput').value, '本地库草稿');
});

test('rename updates the current list and toolbar while preserving draft, messages and other sessions', () => {
  const f = fixture(); f.c.body.getAttribute = key => key === 'data-view' ? 'agent' : 'lg';
  f.run('renderAgent()'); const messages = f.run('JSON.stringify(agentSession().messages)');
  f.get('agentInput').value = '还没发出的草稿';
  assert.equal(f.run('agentRenameSession({vault:"local",id:"reading"}, "  阅读中的反例  ")'), true);
  assert.equal(f.get('appTitle').textContent, '阅读中的反例');
  assert.match(f.get('agentThreads').innerHTML, /阅读中的反例/);
  assert.equal(f.get('agentInput').value, '还没发出的草稿');
  assert.equal(f.run('JSON.stringify(agentSession().messages)'), messages);
  assert.equal(f.run('agentStores.local[1].title'), '下一轮阅读怎么安排');
  f.run("switchVault('otherVault'); renderAgent(); switchVault('local'); renderAgent()");
  assert.equal(f.run('agentSession().title'), '阅读中的反例');
});
test('rename rejects empty, missing and cross-vault targets and preserves an explicit new-chat title', () => {
  const f = fixture(); f.run('renderAgent()');
  for (const expr of [
    'agentRenameSession({vault:"local",id:"reading"}, "  ")',
    'agentRenameSession({vault:"local",id:"missing"}, "标题")',
    'agentRenameSession({vault:"otherVault",id:"reading"}, "标题")'
  ]) assert.equal(f.run(expr), false);
  assert.equal(f.run('agentSession().title'), '从读懂到会用');
  f.get('agentNew').handlers.click();
  f.run('agentRenameSession({vault:currentVault,id:agentSession().id}, "新对话")');
  f.get('agentInput').value = '请追问我'; f.run('agentSend()');
  assert.equal(f.run('agentSession().title'), '新对话');
});

function attachConversationDialogs(f) {
  f.c.cfMode = ''; f.c.cfTarget = ''; f.c.cfType = 'note';
  f.run(html.match(/function updateHint\(\) \{[\s\S]*?\n  \}/)[0]);
  f.run(html.match(/function openDialog\(mode, id\) \{[\s\S]*?\n  \}/)[0]);
  for (const id of ['cfOk', 'cfCancel']) {
    f.run(html.match(new RegExp("document.getElementById\\('" + id + "'\\).addEventListener\\('click', function \\(\\) \\{[\\s\\S]*?\\n  \\}\\);"))[0]);
  }
}
function chatButton(attrs) {
  return { getAttribute: key => attrs[key] || null, hasAttribute: key => key in attrs, closest() { return this; }, classList: { toggle() {} } };
}
test('single-click keeps list rows intact so double-click and F2 can open the rename dialog', () => {
  const f = fixture(); attachConversationDialogs(f); f.run('renderAgent()');
  const button = chatButton({'data-session': 'review'});
  let replacements = 0, list = f.get('agentThreads').innerHTML;
  Object.defineProperty(f.get('agentThreads'), 'innerHTML', { get: () => list, set: value => { list = value; replacements++; } });
  f.get('agentThreads').querySelectorAll = () => [button];
  f.get('agentView').handlers.click({target: button});
  f.get('agentView').handlers.click({target: button});
  assert.equal(replacements, 0);
  assert.equal(f.run('agentSession().id'), 'review');
  f.get('agentThreads').handlers.dblclick({target: button});
  assert.equal(f.get('cfTitle').textContent, '重命名对话');
  assert.equal(f.get('cfInput').value, '下一轮阅读怎么安排');
  assert.equal(f.get('mask').classList.contains('hidden'), false);
  f.get('cfInput').value = '  '; f.run('updateHint()');
  assert.equal(f.get('cfOk').disabled, true); f.get('cfOk').handlers.click();
  assert.equal(f.get('mask').classList.contains('hidden'), false);
  f.get('cfInput').value = '改个标题'; f.get('cfCancel').handlers.click();
  assert.equal(f.run('agentSession().title'), '下一轮阅读怎么安排');
  let prevented = false;
  f.get('agentThreads').handlers.keydown({target:button,key:'F2',preventDefault(){prevented=true;},stopPropagation(){}});
  assert.equal(prevented, true);
  f.get('cfInput').value = '我的阅读计划'; f.get('cfOk').handlers.click();
  assert.equal(f.run('agentSession().title'), '我的阅读计划');
});
test('archive hides conversations, preserves drafts and messages, and restores them through Agent settings', () => {
  const f = fixture(); f.c.body.getAttribute = key => key === 'data-view' ? 'agent' : 'lg'; f.run('renderAgent()');
  const before = f.run('JSON.stringify(agentSession().messages)'); f.get('agentInput').value = '归档前的草稿';
  f.get('agentView').handlers.click({target:chatButton({'data-archive-session':'reading'})});
  assert.equal(f.run('agentSession().id'), 'review');
  assert.doesNotMatch(f.get('agentThreads').innerHTML, /data-session="reading"/);
  assert.equal(f.run('agentStores.local[0].draft'), '归档前的草稿');
  assert.equal(f.run('JSON.stringify(agentStores.local[0].messages)'), before);
  f.run("setSettingsTab('agent')");
  assert.match(f.get('agentHistory').innerHTML, /已归档/);
  assert.match(f.get('agentHistory').innerHTML, /本地笔记/);
  f.get('agentHistory').handlers.click({target:chatButton({'data-restore-chat':'reading','data-chat-vault':'local'})});
  assert.match(f.get('agentThreads').innerHTML, /data-session="reading"/);
  assert.doesNotMatch(f.get('agentHistory').innerHTML, /data-restore-chat="reading"/);
  f.get('agentView').handlers.click({target:chatButton({'data-session':'reading'})});
  assert.equal(f.get('agentInput').value, '归档前的草稿');
});
test('archiving every conversation opens a fresh empty chat and never resurfaces archived samples', () => {
  const f = fixture(); f.run('renderAgent()');
  f.run('agentArchiveSession({vault:"local",id:"reading"}, true); agentArchiveSession({vault:"local",id:"review"}, true)');
  assert.match(f.run('agentSession().id'), /^chat-/);
  assert.equal(f.run('agentSession().messages.length'), 0);
  assert.equal(f.run('agentStores.local.filter(s => s.archived).length'), 3);
  assert.doesNotMatch(f.get('agentThreads').innerHTML, /data-session="(?:reading|review)"/);
});
test('settings deletion requires confirmation, leaves written notes intact, and does not reseed deleted chats', () => {
  const f = fixture(); attachConversationDialogs(f); f.run("agentWrite('append',1)");
  const note = f.c.CONTENT.reading_journal;
  f.run('agentArchiveSession({vault:"local",id:"reading"}, true)');
  const button = chatButton({'data-delete-chat':'reading','data-chat-vault':'local'});
  f.get('agentHistory').handlers.click({target:button});
  assert.match(f.get('cfTitle').textContent, /删除对话/);
  assert.equal(f.run('agentStores.local.some(s => s.id === "reading")'), true);
  f.get('cfCancel').handlers.click();
  assert.equal(f.run('agentStores.local.some(s => s.id === "reading")'), true);
  f.get('agentHistory').handlers.click({target:button}); f.get('cfOk').handlers.click();
  assert.equal(f.run('agentStores.local.some(s => s.id === "reading")'), false);
  assert.equal(f.c.CONTENT.reading_journal, note);
  assert.equal(f.run('agentLastWrite'), null);
  f.run('agentDeleteSession({vault:"local",id:"review"})');
  assert.equal(f.run('agentStores.local.length'), 2);
  assert.equal(f.run('agentStores.local.filter(s => !s.archived).length'), 1);
  assert.equal(f.run('agentSession().messages.length'), 0);
  assert.match(f.run('agentSession().id'), /^chat-/);
  assert.equal(f.run('agentDeleteSession({vault:"local",id:"missing"})'), false);
});
test('history distinguishes identical session IDs in different libraries and its filter does not reset config drafts', () => {
  const f = fixture(); f.run("renderAgent(); switchVault('otherVault'); renderAgent(); switchVault('local'); renderAgent()");
  f.run('agentArchiveSession({vault:"otherVault",id:"reading"}, true)');
  assert.equal(f.run('agentStores.local[0].archived'), undefined);
  assert.match(f.get('agentHistory').innerHTML, /其他库/);
  f.get('configSystemPrompt').value = '还没保存的配置';
  f.get('agentHistoryFilter').value = 'all'; f.get('agentHistoryFilter').handlers.change();
  assert.match(f.get('agentHistory').innerHTML, /本地笔记/);
  assert.match(f.get('agentHistory').innerHTML, /其他库/);
  f.run('agentDeleteSession({vault:"otherVault",id:"reading"})');
  assert.equal(f.run('agentStores.local.some(s => s.id === "reading")'), true);
  assert.equal(f.get('configSystemPrompt').value, '还没保存的配置');
});

test('Agent settings shows archived demo data on first visit and restored/deleted samples stay changed', () => {
  const f = fixture();
  f.run(html.split('/* SAMPLE_VAULT_BEGIN: generated by tools/build_sample_vault.py */')[1].split('/* SAMPLE_VAULT_END */')[0]);
  f.run('settingsReturnView = "agent"; VAULTS.forEach(v => agentInitSessions(v.id)); setSettingsTab("agent")');
  const history = f.get('agentHistory').innerHTML;
  for (const name of ['本地笔记', '阅读笔记', '项目笔记', '整理笔记的三个习惯', '读书时如何记录反例', '每周项目回顾怎么写']) assert.ok(history.includes(name), name);
  assert.equal((history.match(/data-restore-chat=/g) || []).length, 3);
  assert.equal((history.match(/data-delete-chat=/g) || []).length, 3);
  assert.doesNotMatch(f.get('agentThreads').innerHTML, /archive-sample/);
  f.run('agentArchiveSession({vault:"reading",id:"archive-sample"}, false); agentDeleteSession({vault:"projects",id:"archive-sample"}); setSettingsTab("general"); setSettingsTab("agent")');
  assert.doesNotMatch(f.get('agentHistory').innerHTML, /读书时如何记录反例|每周项目回顾怎么写/);
  f.get('agentHistoryFilter').value = 'all'; f.get('agentHistoryFilter').handlers.change();
  assert.match(f.get('agentHistory').innerHTML, /读书时如何记录反例/);
  assert.doesNotMatch(f.get('agentHistory').innerHTML, /每周项目回顾怎么写/);
});

test('sm push navigation disables the offscreen Agent list and preserves panels and draft when closed', () => {
  const f = fixture(); f.c.body.getAttribute = key => key === 'data-form' ? 'sm' : 'agent';
  f.run('renderAgent(); setAgentNavOpen(false)');
  f.get('agentInput').value = '保留草稿';
  assert.equal(f.get('agentNav').inert, true);
  f.run('toggleAgentNavigation()');
  assert.equal(f.get('agentNav').inert, false);
  assert.equal(f.get('agentNav').getAttribute('aria-hidden'), 'false');
  f.run('toggleAgentNavigation()');
  assert.equal(f.get('agentNav').inert, true);
  assert.equal(f.run('agentPanels.threads && agentPanels.files'), true);
  assert.equal(f.get('agentInput').value, '保留草稿');
  f.c.body.getAttribute = () => 'lg'; f.run('setAgentNavOpen(false)');
  assert.equal(f.get('agentNav').inert, false);
});

function settingsNavigationFixture(form = 'sm', landscape = false) {
  const f = fixture(), attrs = {'data-form':form,'data-view':'note','data-single-landscape':String(landscape)};
  f.c.body.getAttribute = key => attrs[key]; f.c.body.setAttribute = (key,value) => {attrs[key]=value;};
  f.c.document.querySelectorAll = () => [];
  for (const name of ['closeQuick','closeImage','closeShare','closeCelia','closeFormatPanel','updateAppTitle','syncUrl','updateSettings']) f.c[name] = () => {};
  f.run(html.match(/function setView\(v, syncBtns\) \{[\s\S]*?\n  \}/)[0]);
  f.run('function setViewBtn(v) { setView(v, true); }');
  f.run(html.match(/document.getElementById\('backBtn'\).addEventListener\('click', function \(\) \{[\s\S]*?\n  \}\);/)[0]);
  return {...f, attrs};
}
test('single-screen settings opens a vertical category list, drills into content and returns in two steps', () => {
  const f = settingsNavigationFixture(); f.run('setView("settings", true)');
  assert.equal(f.get('settingsView').getAttribute('data-settings-page'), 'list');
  assert.equal(f.get('settingsNav').getAttribute('role'), 'navigation');
  for (const tab of ['general','data','feedback','about']) {
    assert.equal(f.get('settings-'+tab).classList.contains('hidden'), true);
    assert.equal(f.get('settings-tab-'+tab).getAttribute('tabindex'), '0');
  }
  assert.equal(f.get('settings-tab-agent').classList.contains('hidden'), true);
  assert.equal(f.get('settings-tab-agent').getAttribute('tabindex'), '-1');
  f.run('setSettingsTab("agent")');
  assert.equal(f.get('settings-agent').classList.contains('hidden'), true);
  f.get('configSystemPrompt').value = '未保存配置';
  f.get('settings-tab-data').handlers.click();
  assert.equal(f.get('settingsView').getAttribute('data-settings-page'), 'detail');
  assert.equal(f.get('settings-data').classList.contains('hidden'), false);
  assert.equal(f.get('appTitle').textContent, '数据');
  f.get('backBtn').handlers.click();
  assert.equal(f.attrs['data-view'], 'settings');
  assert.equal(f.get('settingsView').getAttribute('data-settings-page'), 'list');
  assert.equal(f.get('appTitle').textContent, '设置与关于');
  assert.equal(f.get('configSystemPrompt').value, '未保存配置');
  f.get('backBtn').handlers.click(); assert.equal(f.attrs['data-view'], 'note');
});
for (const form of ['md','lg']) test(`${form}: settings retains vertical tabs and one visible content panel while switching`, () => {
  const f = settingsNavigationFixture(form); f.run('setView("settings")');
  assert.equal(f.get('settingsNav').getAttribute('role'), 'tablist');
  assert.equal(f.get('settingsNav').getAttribute('aria-orientation'), 'vertical');
  assert.equal(f.get('settings-general').classList.contains('hidden'), false);
  f.get('settings-tab-general').handlers.keydown({key:'ArrowDown',preventDefault(){}});
  assert.equal(f.get('settings-data').classList.contains('hidden'), false);
  assert.equal(f.get('settings-general').classList.contains('hidden'), true);
  assert.equal(f.get('settings-tab-data').getAttribute('aria-selected'), 'true');
  f.get('configSystemPrompt').value = '跨布局保留';
  f.attrs['data-form'] = 'sm'; f.run('renderSettingsNavigation()');
  assert.equal(f.get('settings-data').classList.contains('hidden'), false);
  assert.equal(f.get('appTitle').textContent, '数据');
  f.attrs['data-form'] = form; f.run('renderSettingsNavigation()');
  assert.equal(f.get('configSystemPrompt').value, '跨布局保留');
});
test('rotated single screen retains category/detail navigation and Agent shortcut preserves its return workspace', () => {
  const f = settingsNavigationFixture('md', true); f.attrs['data-view'] = 'agent';
  f.run('setView("settings"); setSettingsTab("agent")');
  assert.equal(f.get('settingsNav').getAttribute('role'), 'navigation');
  assert.equal(f.get('settingsView').getAttribute('data-settings-page'), 'detail');
  f.get('backBtn').handlers.click(); assert.equal(f.get('settingsView').getAttribute('data-settings-page'), 'list');
  f.get('backBtn').handlers.click(); assert.equal(f.attrs['data-view'], 'agent');
});

for (const form of ['md','lg']) test(`${form}: hamburger collapse keeps width state and disables the hidden animated Agent rail`, () => {
  const f = fixture(); f.c.body.getAttribute = key => key === 'data-form' ? form : 'agent';
  f.run('renderAgent(); toggleAgentNavigation()');
  assert.equal(f.get('agentNav').classList.contains('hidden'), true);
  assert.equal(f.get('agentNav').inert, true);
  assert.equal(f.get('agentNav').getAttribute('aria-hidden'), 'true');
  f.run('toggleAgentNavigation()');
  assert.equal(f.get('agentNav').classList.contains('hidden'), false);
  assert.equal(f.get('agentNav').inert, false);
});
