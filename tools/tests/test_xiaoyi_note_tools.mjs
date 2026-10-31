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

const methods = ['appendText', 'replaceUniqueAnchor', 'resolveVaultId'].map(extractStaticMethod).join('\n');
const code = transformSync(methods, { loader: 'ts', format: 'cjs' }).code +
  '\nmodule.exports = { appendText, replaceUniqueAnchor, resolveVaultId };';
const module = { exports: {} };
vm.runInContext(code, vm.createContext({ module, exports: module.exports, Error }));
const { appendText, replaceUniqueAnchor, resolveVaultId } = module.exports;

assert.equal(appendText('', 'new'), 'new');
assert.equal(appendText('old', 'new'), 'old\nnew');
assert.equal(appendText('old\n', 'new'), 'old\nnew');
assert.equal(replaceUniqueAnchor('before target after', 'target', 'updated'), 'before updated after');
assert.throws(() => replaceUniqueAnchor('same same', 'same', 'x'), /ANCHOR_NOT_UNIQUE/);
assert.throws(() => replaceUniqueAnchor('before', 'missing', 'x'), /ANCHOR_NOT_UNIQUE/);
assert.throws(() => replaceUniqueAnchor('whole note', 'whole note', ''), /WHOLE_NOTE_DELETE_DENIED/);
assert.equal(resolveVaultId({ vaultId: 'vault-a' }, 'vault-b'), 'vault-a');
assert.equal(resolveVaultId({ vaultId: '  vault-a  ' }, 'vault-b'), 'vault-a');
assert.equal(resolveVaultId({}, 'vault-b'), 'vault-b');
assert.equal(resolveVaultId({ vaultId: '' }, 'vault-b'), 'vault-b');
assert.throws(() => resolveVaultId({}, ''), /NO_CURRENT_VAULT/);
assert.throws(() => resolveVaultId({ vaultId: '' }, ''), /NO_CURRENT_VAULT/);

const guardSource = fs.readFileSync(new URL('../../entry/src/main/ets/model/WorkspaceEditGuard.ets', import.meta.url),
  'utf8').replace(/^export class WorkspaceEditGuard/m, 'class WorkspaceEditGuard');
const guardCode = transformSync(guardSource, { loader: 'ts', format: 'cjs' }).code +
  '\nmodule.exports = { WorkspaceEditGuard };';
const guardModule = { exports: {} };
vm.runInContext(guardCode, vm.createContext({ module: guardModule, exports: guardModule.exports, Map }));
const { WorkspaceEditGuard } = guardModule.exports;
WorkspaceEditGuard.mark('left', 'vault-a', 'note.md');
WorkspaceEditGuard.mark('right', 'vault-b', 'note.md');
assert.equal(WorkspaceEditGuard.isUnsaved('vault-a', 'note.md'), true);
assert.equal(WorkspaceEditGuard.isUnsaved('vault-b', 'note.md'), true);
assert.equal(WorkspaceEditGuard.isUnsaved('vault-c', 'note.md'), false);
WorkspaceEditGuard.clear('left', 'vault-a', 'other.md');
assert.equal(WorkspaceEditGuard.isUnsaved('vault-a', 'note.md'), true);
WorkspaceEditGuard.clear('left', 'vault-a', 'note.md');
assert.equal(WorkspaceEditGuard.isUnsaved('vault-a', 'note.md'), false);
assert.equal(WorkspaceEditGuard.isUnsaved('vault-b', 'note.md'), true);

const profile = JSON.parse(fs.readFileSync(new URL('../../entry/src/main/resources/base/profile/insight_intent.json',
  import.meta.url), 'utf8'));
const expected = ['ListVaults', 'CreateVault', 'QueryNotes', 'ReadNote', 'CreateNote', 'AppendNote', 'EditNote',
  'UndoLastEdit'];
const actual = profile.insightIntents.map((intent) => intent.intentName);
assert.deepEqual([...actual].sort(), [...expected].sort());
assert.equal(new Set(actual).size, expected.length, 'intent names must be unique');
for (const intent of profile.insightIntents) {
  assert.equal(intent.srcEntry, './ets/entryability/InsightIntentExecutorImpl.ets');
  assert.deepEqual(intent.uiAbility.executeMode, ['background']);
}

const executor = fs.readFileSync(new URL('../../entry/src/main/ets/entryability/InsightIntentExecutorImpl.ets',
  import.meta.url), 'utf8');
const noteService = fs.readFileSync(new URL('../../entry/src/main/ets/entryability/InsightIntentNoteService.ets',
  import.meta.url), 'utf8');
const noteStorage = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteService.ets', import.meta.url), 'utf8');
const index = fs.readFileSync(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const agentKitSlot = fs.readFileSync(new URL('../../entry/src/main/ets/components/AgentKitSlot.ets', import.meta.url), 'utf8');

for (const name of expected.slice(2)) {
  assert.ok(executor.includes(`'${name}'`), `${name} must be dispatched`);
  assert.ok(noteService.includes(`name === '${name}'`), `${name} must reach its local implementation`);
}
for (const method of ['queryNotes', 'readNote', 'createNote', 'appendNote', 'editNote', 'undoLastEdit']) {
  const start = noteService.search(new RegExp(`private (?:async )?${method}\\(`));
  assert.ok(start >= 0, `missing ${method}`);
  assert.ok(noteService.slice(start, start + 300).includes('InsightIntentNoteService.resolveVaultId(params, this.registry.currentId())'),
    `${method} must resolve vaultId with an explicit-current fallback`);
}
assert.ok(noteService.includes('NO_CURRENT_VAULT'), 'omitted vaultId without a current vault must fail explicitly');
assert.ok(noteService.includes('requireExistingNote(vaultId, path)'));
assert.ok(noteService.includes('NoteService.saveNoteIfUnchanged'));
assert.ok(noteService.includes('NoteService.deleteNoteIfUnchanged'));
assert.ok(noteService.includes('WorkspaceEditGuard.isUnsaved(vaultId, path)'));
assert.ok(noteStorage.includes('new fileIo.AtomicFile('), 'existing-note writes must use AtomicFile');
assert.ok(index.includes("import('../components/AgentKitSlot')"), 'the note workspace must load the platform component');
assert.ok(agentKitSlot.includes('FunctionComponent({'), 'the AgentKit slot must expose the platform component');
assert.ok(agentKitSlot.includes("this.controller.on('agentDialogClosed'"), 'closing the panel must be observed');
assert.ok(index.includes('refreshWorkspaceAfterXiaoyi'), 'closing the panel must refresh local files');

console.log('小艺端工具参数、意图映射、文本变换与安全接线检查通过（不代表平台调用或设备验收）');
