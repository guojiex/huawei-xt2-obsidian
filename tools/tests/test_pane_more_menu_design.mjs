import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

const index = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const prototype = readSourceFile(
  new URL('../../docs/prototype/v2/index.html', import.meta.url));

const paneHeadStart = index.indexOf('  PaneHead($$: PaneHeadParam) {');
const paneHeadEnd = index.indexOf('\n  @Builder\n  PaneTitle(', paneHeadStart);
const paneHead = index.slice(paneHeadStart, paneHeadEnd);
const noteGroupStart = index.indexOf('  MobileMoreMenuNoteGroup() {');
const noteGroupEnd = index.indexOf('\n  @Builder\n  MobileMoreMenuExperienceGroup(', noteGroupStart);
const noteGroup = index.slice(noteGroupStart, noteGroupEnd);

test('pane headers have no more button; active note scope appears in the top menu', () => {
  assert.ok(paneHeadStart >= 0 && paneHeadEnd > paneHeadStart);
  assert.doesNotMatch(paneHead, /PaneMoreButton/);
  assert.match(index, /private activeNoteMenuScopeLabel\(\)/);
  assert.match(noteGroup, /Text\(this\.activeNoteMenuScopeLabel\(\)\)/);
  assert.match(index, /当前笔记 · '\s*\+ \(this\.activeNotePane\(\) === 'right' \? '右栏' : '左栏'\)/);
  assert.match(index, /workspace-more-button/);
});

test('the shared top menu keeps actions scoped to the active pane', () => {
  assert.match(noteGroup, /this\.openShareNoteDialog\(\)/);
  assert.match(noteGroup, /this\.toggleBacklinks\(this\.activeNotePane\(\)\)/);
  assert.match(noteGroup, /this\.previewActiveNoteInOtherPane\(this\.activeNotePane\(\)\)/);
  assert.match(noteGroup, /this\.setPreviewFollowEnabled\(!this\.followPreviewEnabled\)/);
  assert.match(noteGroup, /this\.openBlockPropertyPanel\(this\.activeNotePane\(\)\)/);
  assert.match(noteGroup, /this\.toggleActivePane\(\)/);
});

test('the prototype also exposes one top-level menu entry', () => {
  assert.match(prototype, /\.pane-title-row \.pane-more\{display:none\}/);
  assert.match(prototype, /\.topbar>\.mobile-top-more\{display:block\}/);
});
