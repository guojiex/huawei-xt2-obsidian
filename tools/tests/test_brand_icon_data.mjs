import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const assetPath = new URL('../../docs/assets/app_icon_1024.png', import.meta.url);
const resourcePath = new URL('../../entry/src/main/resources/base/media/app_icon_1024.png', import.meta.url);
const sidebarPath = new URL('../../entry/src/main/ets/components/VaultSidebar.ets', import.meta.url);
const settingsPath = new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url);
const fileTreePath = new URL('../../entry/src/main/ets/components/FileTreeView.ets', import.meta.url);
const iconsPath = new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url);
const prototypePath = new URL('../../docs/prototype/v2/index.html', import.meta.url);

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

test('native workspace and about UI use the current v2 brand icon resource', () => {
  const sourceHash = sha256(readFileSync(assetPath));
  const packagedHash = sha256(readFileSync(resourcePath));
  const sidebar = readFileSync(sidebarPath, 'utf8');
  const settings = readFileSync(settingsPath, 'utf8');

  assert.equal(packagedHash, sourceHash, 'packaged media must match the v2 design asset');
  assert.match(sidebar, /Image\(\$r\('app\.media\.app_icon_1024'\)\)[\s\S]{0,180}\.width\(Space\.s10\)[\s\S]{0,100}\.height\(Space\.s10\)/);
  assert.match(settings, /Image\(\$r\('app\.media\.app_icon_1024'\)\)[\s\S]{0,180}\.width\(Space\.s16\)[\s\S]{0,100}\.height\(Space\.s16\)/);
});

test('native file-reference action matches the v2 icon geometry and size', () => {
  const prototype = readFileSync(prototypePath, 'utf8');
  const icons = readFileSync(iconsPath, 'utf8');
  const fileTree = readFileSync(fileTreePath, 'utf8');

  assert.match(prototype, /columns:'<rect x="3" y="4" width="18" height="16" rx="3"\/><path d="M11 4v16"\/>/);
  assert.match(icons, /const P_FILE_REFERENCE: string = '[^']*M11 4v16';/);
  assert.match(icons, /name === 'fileReference'[\s\S]{0,90}return P_FILE_REFERENCE;/);
  assert.match(fileTree, /Icon\('fileReference', Space\.s5, \$r\('app\.color\.text_secondary'\), 1\.7\)/);
  assert.doesNotMatch(fileTree, /Icon\('swap', 16,/);
});

test('native file-tree note icon matches the v2 note glyph and metrics', () => {
  const prototype = readFileSync(prototypePath, 'utf8');
  const icons = readFileSync(iconsPath, 'utf8');
  const fileTree = readFileSync(fileTreePath, 'utf8');
  const tokens = readFileSync(new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url), 'utf8');

  assert.match(prototype, /note:'<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M8 13h8M8 17h5"\/>/);
  assert.match(icons, /const P_NOTE: string = 'M14 3H6C4\.9 3 4 3\.9 4 5V19C4 20\.1 4\.9 21 6 21H18C19\.1 21 20 20\.1 20 19V9ZM14 3V9H20M8 13H16M8 17H13';/);
  assert.match(icons, /name === 'note'[\s\S]{0,70}return P_NOTE;/);
  assert.match(tokens, /static readonly treeIcon: number = 18;/);
  assert.match(fileTree, /Icon\(n\.isDir \? 'folder' : 'note', Size\.treeIcon,[\s\S]{0,200}1\.7\)/);
  assert.match(fileTree, /n\.relPath === this\.currentFilePath[\s\S]{0,100}\$r\('app\.color\.brand'\)/);
  assert.doesNotMatch(fileTree, /Icon\(n\.isDir \? 'folder' : 'doc', 18,/);
});
