import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const index = fs.readFileSync(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const icons = fs.readFileSync(
  new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url), 'utf8');
const prototype = fs.readFileSync(
  new URL('../../docs/prototype/v2/index.html', import.meta.url), 'utf8');

const itemStart = index.indexOf('  PaneMoreMenuItem(');
const itemEnd = index.indexOf('\n  @Builder\n  PaneMoreMenu(', itemStart);
const menuStart = index.indexOf('  PaneMoreMenu(pane: string) {', itemEnd);
const menuEnd = index.indexOf('\n  @Builder\n  PaneMoreButton(', menuStart);
assert.ok(itemStart >= 0 && itemEnd > itemStart, 'could not find Index.PaneMoreMenuItem');
assert.ok(menuStart >= 0 && menuEnd > menuStart, 'could not find Index.PaneMoreMenu');
const item = index.slice(itemStart, itemEnd);
const menu = index.slice(menuStart, menuEnd);

test('pane menu rows use v2 touch, body, nav-hover, and small-radius tokens', () => {
  assert.match(item, /Icon\(icon, Space\.s5,/);
  assert.match(item, /FontSize\.body1/);
  assert.match(item, /\.height\(Size\.touch\)/);
  assert.match(item, /\.borderRadius\(Radius\.control\)/);
  assert.match(item, /app\.color\.bg_secondary/);
  assert.match(item, /\.onHover\(\(isHover: boolean\)/);
  assert.match(menu, /\.padding\(Space\.s1\)/);
  assert.match(menu, /\.borderRadius\(Radius\.menu\)/);
  assert.match(prototype, /\.pane-more:not\(\.mobile-top-more\) \.pane-more-menu button:hover\{background:var\(--nav\)\}/);
});

test('existing pane actions remain and use the v1.31 line icons', () => {
  assert.match(menu, /'follow', 'follow'/);
  assert.match(menu, /'preview', 'fileReference'/);
  assert.match(menu, /'block', 'settings'/);
  assert.match(menu, /'backlinks', 'link'/);
  assert.match(icons, /const P_LINK: string =/);
  assert.match(icons, /const P_FOLLOW: string = 'M7 4v16M17 4v16M4 9l3-3 3 3M14 15l3 3 3-3'/);
  assert.match(icons, /name === 'link'/);
  assert.match(icons, /name === 'follow'/);
});

test('menu item handlers preserve the original operations', () => {
  assert.match(index, /action === 'follow'[\s\S]*setPreviewFollowEnabled/);
  assert.match(index, /action === 'preview'[\s\S]*previewActiveNoteInOtherPane/);
  assert.match(index, /action === 'block'[\s\S]*openBlockPropertyPanel/);
  assert.match(index, /toggleBacklinks\(pane\)/);
});
