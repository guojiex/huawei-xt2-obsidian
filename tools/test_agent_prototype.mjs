import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const script = html.split('/* AGENT_DESIGN_BEGIN:')[1].split('/* AGENT_DESIGN_END */')[0];
const code = script.slice(script.indexOf('var agentStores'));
function fixture() {
  const nodes = new Map();
  const get = (id) => {
    if (!nodes.has(id)) {
      const attrs = {}, classes = new Set();
      nodes.set(id, { value: '', innerHTML: '', textContent: '', handlers: {}, scrollTop: 0,
        classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c), contains: (c) => classes.has(c) },
        addEventListener(type, fn) { this.handlers[type] = fn; },
        setAttribute(k, v) { attrs[k] = v; }, getAttribute(k) { return attrs[k]; }, focus() {}, contains() { return false; }
      });
    }
    return nodes.get(id);
  };
  const c = vm.createContext({ document: { getElementById: get },
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
  vm.runInContext(code, c);
  return { c, get, run: (s) => vm.runInContext(s, c) };
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
  assert.match(f.get('agentMessages').innerHTML, /演示回复/);
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
