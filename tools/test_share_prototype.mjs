import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');

function shareHelpersFixture() {
  const TREES = {
    local: [
      ['dir', '10_写作', true, 0], ['dir', '2026', true, 1], ['file', '周记.md', false, 2, 'journal'],
      ['file', '清单.md', false, 1, 'checklist'], ['dir', '20_样式', true, 0],
      ['file', '预览.svg', false, 1, 'preview']
    ]
  };
  const FILES = { journal: '周记.md', checklist: '清单.md', preview: '预览.svg' };
  const start = html.indexOf('  function collectShareRows(');
  const end = html.indexOf('  function openShare(', start);
  const helperSource = html.slice(start, end);
  const fileRowsStart = html.indexOf('  function fileRowsForVault(');
  const fileRowsEnd = html.indexOf('  function currentFileRows()', fileRowsStart);
  const fileRowsSource = html.slice(fileRowsStart, fileRowsEnd);
  const context = vm.createContext({ TREES, FILES, decodeURIComponent, encodeURIComponent });
  vm.runInContext(fileRowsSource + helperSource, context);
  return context;
}

test('share scope collection uses the selected subtree or the full vault', () => {
  const c = shareHelpersFixture();
  assert.equal(c.folderPathForRow('local', 1), '10_写作/2026');
  assert.deepEqual(Array.from(c.collectShareRows('local', 'folder', '10_写作', 'journal'), row => row.path),
    ['10_写作/2026/周记.md', '10_写作/清单.md']);
  assert.deepEqual(Array.from(c.collectShareRows('local', 'note', '', 'checklist'), row => row.path),
    ['10_写作/清单.md']);
  assert.equal(c.collectShareRows('local', 'vault', '', '').length, 3);
});

test('Git share links distinguish notes, folders, and repository roots with encoded paths', () => {
  const c = shareHelpersFixture();
  const github = { type: 'git', remote: 'github.com/example/notes.git', branch: 'feature/编辑' };
  assert.equal(c.buildPrototypeShareLink(github, 'note', '10_写作/周记 2026.md'),
    'https://github.com/example/notes/blob/feature%2F%E7%BC%96%E8%BE%91/10_%E5%86%99%E4%BD%9C/%E5%91%A8%E8%AE%B0%202026.md');
  assert.equal(c.buildPrototypeShareLink(github, 'folder', '10_写作/2026'),
    'https://github.com/example/notes/tree/feature%2F%E7%BC%96%E8%BE%91/10_%E5%86%99%E4%BD%9C/2026');
  assert.equal(c.buildPrototypeShareLink(github, 'vault', ''), 'https://github.com/example/notes');
  assert.equal(c.buildPrototypeShareLink({ ...github, remote: 'git.example.com/team/notes' }, 'vault', ''), '');
});

test('prototype exposes folder and local vault sharing while keeping delivery clearly simulated', () => {
  assert.match(html, /id="shareVaultBtn" data-intro="v0\.8">分享知识库/);
  assert.match(html, /data-act="share" title="分享文件夹"/);
  assert.match(html, /data-share-step="archive"/);
  assert.match(html, /本原型不调用系统分享/);
  assert.match(html, /ZIP 来自设备当前文件/);
  assert.match(html, /私有仓库需要接收人拥有访问权限/);
});
