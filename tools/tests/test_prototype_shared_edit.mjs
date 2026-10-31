import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');
const sharedEditability = html.match(/function syncSharedEditability\(\)\{[^}]*\}/)?.[0];
assert.ok(sharedEditability, 'prototype must keep one editable source for a shared note');

function apply(current, reference, activePane) {
  const nodes = { editor: { readOnly: false }, rightEditor: { readOnly: false } };
  const context = vm.createContext({
    current,
    reference,
    activePane,
    $: (id) => nodes[id]
  });
  vm.runInContext(`${sharedEditability};syncSharedEditability()`, context);
  return nodes;
}

test('same note leaves only the active pane editable', () => {
  const left = apply('note-a', 'note-a', 'left');
  assert.equal(left.editor.readOnly, false);
  assert.equal(left.rightEditor.readOnly, true);

  const right = apply('note-a', 'note-a', 'right');
  assert.equal(right.editor.readOnly, true);
  assert.equal(right.rightEditor.readOnly, false);
});

test('different notes remain independently editable', () => {
  const panes = apply('note-a', 'note-b', 'left');
  assert.equal(panes.editor.readOnly, false);
  assert.equal(panes.rightEditor.readOnly, false);
});
