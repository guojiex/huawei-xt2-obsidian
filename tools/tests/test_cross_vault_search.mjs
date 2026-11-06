import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

// ---------------------------------------------------------------------------
// v1.35 跨库搜索：CrossVaultSearchService（行为）+ QuickSwitcher（结构）+ Index（接线）+ 原型。
// 范式与 test_git_sync_badge.mjs / test_quick_switcher_logic.mjs 相同：
// readSourceFile 归一 CRLF 后按标记切片，esbuild transformSync 抽成可在 vm 里跑的类。
// ---------------------------------------------------------------------------

const serviceSource = readSourceFile(new URL('../../entry/src/main/ets/model/CrossVaultSearchService.ets', import.meta.url));
const quickSwitcherSource = readSourceFile(new URL('../../entry/src/main/ets/components/QuickSwitcher.ets', import.meta.url));
const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const prototypeSource = readSourceFile(new URL('../../docs/prototype/v2/index.html', import.meta.url));

// vm 里创建的数组/对象与断言侧分属两个 realm，deepStrictEqual 会因原型不同而失败；
// 统一 JSON 往返归一成本地对象再比较。
const plain = (value) => JSON.parse(JSON.stringify(value));

// ---------------------------- CrossVaultSearchService 行为 ----------------------------

const classBody = serviceSource.slice(serviceSource.indexOf('export class CrossVaultSearchService')).trim();
const serviceCode = transformSync(`${classBody.replace('export class', 'class')}\nmodule.exports = CrossVaultSearchService;`,
  { loader: 'ts', format: 'cjs' }).code;

function createServiceHarness({
  vaults,
  currentVaultId,
  filesByVault = {},
  contentsByVault = {},
  failVaults = [],
  fullTextResults = [],
  onAllNotesOf = null
} = {}) {
  const calls = [];
  const vaultsArg = vaults.map((id) => ({ id }));
  const registry = {
    accessFor(id) {
      calls.push(`access:${id}`);
      if (failVaults.includes(id)) {
        throw new Error('unreadable vault');
      }
      return {
        id,
        readText(path) {
          calls.push(`read:${id}:${path}`);
          return (contentsByVault[id] || {})[path] || '';
        }
      };
    }
  };
  const context = vm.createContext({
    module: { exports: {} },
    setTimeout,
    FileTree: {
      allNotesOf(access) {
        calls.push(`list:${access.id}`);
        if (onAllNotesOf) {
          onAllNotesOf(access.id);
        }
        return filesByVault[access.id] || [];
      }
    },
    SearchIndex: class {
      constructor() {
        calls.push('index:new');
        this.entries = new Map();
      }
      addOrReplace(path, content) {
        this.entries.set(path, content);
      }
      search(query) {
        calls.push(`index:search:${query}`);
        const results = [];
        for (const [path, content] of this.entries) {
          if (content.toLowerCase().includes(query.toLowerCase())) {
            results.push({ path, excerpt: content.slice(0, 20) });
          }
        }
        return results;
      }
    },
    FullTextSearchService: {
      async search(registryArg, vaultId, query) {
        calls.push(`fts:${vaultId}:${query}`);
        return fullTextResults;
      }
    }
  });
  vm.runInContext(serviceCode, context);
  return { service: context.module.exports, registry, vaultsArg, calls };
}

test('v1.35 35.2 orders groups with the current vault first and keeps registry order for the rest', async () => {
  const { service, registry, vaultsArg, calls } = createServiceHarness({
    vaults: ['alpha', 'beta', 'work', 'gamma'],
    currentVaultId: 'work',
    filesByVault: {
      alpha: ['Alpha/Needle.md'],
      beta: ['Beta/Needle.md'],
      work: ['Work/Needle.md'],
      gamma: ['Gamma/Needle.md']
    }
  });
  const started = [];
  const outcome = await service.run(registry, vaultsArg, 'work', 'needle', 'name',
    (vaultName) => started.push(vaultName));
  assert.deepEqual(plain(outcome.groups.map((group) => group.vaultId)), ['work', 'alpha', 'beta', 'gamma']);
  assert.deepEqual(started, ['work', 'alpha', 'beta', 'gamma']);
  assert.equal(outcome.groups[0].isCurrentVault, true);
  assert.equal(outcome.groups[1].isCurrentVault, false);
  assert.deepEqual(calls.filter((call) => call.startsWith('list:')), ['list:work', 'list:alpha', 'list:beta', 'list:gamma']);
});

test('v1.35 35.6 skips unreadable vaults and records their names without failing the whole search', async () => {
  const { service, registry, vaultsArg } = createServiceHarness({
    vaults: ['alpha', 'broken', 'work'],
    currentVaultId: 'work',
    filesByVault: { alpha: ['Alpha/Needle.md'], work: ['Work/Needle.md'] },
    failVaults: ['broken']
  });
  const outcome = await service.run(registry, vaultsArg, 'work', 'needle', 'name', () => {});
  assert.deepEqual(plain(outcome.skippedVaultNames), ['broken']);
  assert.deepEqual(plain(outcome.groups.map((group) => group.vaultId)), ['work', 'alpha']);
});

test('v1.35 technical constraint: a newer search cancels the in-flight one at the vault boundary', async () => {
  let cancelled = false;
  const { service, registry, vaultsArg, calls } = createServiceHarness({
    vaults: ['alpha', 'beta', 'gamma'],
    currentVaultId: 'alpha',
    filesByVault: { alpha: ['Alpha/Needle.md'], beta: ['Beta/Needle.md'], gamma: ['Gamma/Needle.md'] },
    onAllNotesOf: (id) => {
      if (id === 'alpha' && !cancelled) {
        cancelled = true;
        service.cancel();
      }
    }
  });
  const outcome = await service.run(registry, vaultsArg, 'alpha', 'needle', 'name', () => {});
  assert.deepEqual(plain(outcome.groups.map((group) => group.vaultId)), ['alpha']);
  assert.ok(!calls.includes('list:beta'));
  assert.ok(!calls.includes('list:gamma'));
});

test('v1.35 empty query returns an empty outcome without touching any vault', async () => {
  const { service, registry, vaultsArg, calls } = createServiceHarness({
    vaults: ['alpha', 'work'],
    currentVaultId: 'work'
  });
  const outcome = await service.run(registry, vaultsArg, 'work', '   ', 'name', () => {});
  assert.deepEqual(plain(outcome), { groups: [], skippedVaultNames: [] });
  assert.deepEqual(calls, []);
});

test('v1.35 35.2 content search keeps the current vault on FullTextSearchService and temporary indexes for the rest', async () => {
  const { service, registry, vaultsArg, calls } = createServiceHarness({
    vaults: ['alpha', 'work'],
    currentVaultId: 'work',
    filesByVault: { alpha: ['Alpha/Note.md'] },
    contentsByVault: { alpha: { 'Alpha/Note.md': 'needle in alpha content' } },
    fullTextResults: [{ path: 'Work/Note.md', excerpt: 'needle in work' }]
  });
  const outcome = await service.run(registry, vaultsArg, 'work', 'needle', 'content', () => {});
  assert.ok(calls.includes('fts:work:needle'));
  assert.ok(!calls.includes('fts:alpha:needle'));
  assert.ok(calls.includes('index:new'));
  assert.deepEqual(plain(outcome.groups.map((group) => group.vaultId)), ['work', 'alpha']);
  assert.equal(outcome.groups[1].hits[0].excerpt, 'needle in alpha cont');
});

test('v1.35 name search matches file names and paths case-insensitively', async () => {
  const { service, registry, vaultsArg } = createServiceHarness({
    vaults: ['work'],
    currentVaultId: 'work',
    filesByVault: { work: ['20_样式/FoldedNeedle.md', '2026/周报.md', '根目录.md'] }
  });
  const outcome = await service.run(registry, vaultsArg, 'work', 'NEEDLE', 'name', () => {});
  assert.deepEqual(plain(outcome.groups[0].hits.map((hit) => hit.path)), ['20_样式/FoldedNeedle.md']);
  const byFolder = await service.run(registry, vaultsArg, 'work', '2026/周', 'name', () => {});
  assert.deepEqual(plain(byFolder.groups[0].hits.map((hit) => hit.path)), ['2026/周报.md']);
});

test('v1.35 privacy constraint: query words and note contents never reach logs in the service', () => {
  assert.doesNotMatch(serviceSource, /hilog|console\.|HiLog/);
});

// ---------------------------- Index.ets：selectQuickSwitchFile 行为（35.4） ----------------------------

function extractIndexMethod(startMarker, endMarker) {
  const start = indexSource.indexOf(startMarker);
  const end = indexSource.indexOf(endMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index method ${startMarker}`);
  return indexSource.slice(start, end).trim();
}

const selectCode = transformSync(`
class SelectHarness {
  ${extractIndexMethod('  private async selectQuickSwitchFile(vaultId: string, relPath: string): Promise<void> {', '\n  private isCurrentLeftOpenTarget')}
}
module.exports = SelectHarness;
`, { loader: 'ts', format: 'cjs' }).code;

function createSelectHarness({
  currentVaultId = 'work',
  targetVaultId = 'work',
  switchInProgress = false,
  switchSucceeds = true
} = {}) {
  const calls = [];
  const context = vm.createContext({
    module: { exports: {} },
    promptAction: {
      showToast({ message }) {
        calls.push(`toast:${message}`);
      }
    }
  });
  vm.runInContext(selectCode, context);
  const app = new context.module.exports();
  app.currentVaultId = currentVaultId;
  app.vaultSwitchInProgress = switchInProgress;
  app.quickSwitchOpen = true;
  app.quickSwitchTargetPane = 'right';
  app.switchVault = async (id) => {
    calls.push(`switch:${id}`);
    if (switchSucceeds) {
      app.currentVaultId = id;
    }
  };
  app.onSelectFile = (relPath, pane, focus) => {
    calls.push(`open:${relPath}:${pane}:${focus}`);
  };
  return { app, calls, targetVaultId };
}

test('v1.35 35.4 opens a current-vault result without switching vaults', async () => {
  const { app, calls, targetVaultId } = createSelectHarness({ currentVaultId: 'work', targetVaultId: 'work' });
  await app.selectQuickSwitchFile('work', 'Work/Note.md');
  assert.deepEqual(calls, ['open:Work/Note.md:right:true']);
  assert.equal(app.quickSwitchOpen, false);
});

test('v1.35 35.4 switches to the vault first, then opens the note from the other vault', async () => {
  const { app, calls } = createSelectHarness({ currentVaultId: 'work', targetVaultId: 'alpha', switchSucceeds: true });
  await app.selectQuickSwitchFile('alpha', 'Alpha/Note.md');
  assert.deepEqual(calls, ['switch:alpha', 'open:Alpha/Note.md:right:true']);
  assert.equal(app.quickSwitchOpen, false);
});

test('v1.35 35.4 keeps the user in the original vault and does not open the note when the switch fails', async () => {
  const { app, calls } = createSelectHarness({ currentVaultId: 'work', targetVaultId: 'alpha', switchSucceeds: false });
  await app.selectQuickSwitchFile('alpha', 'Alpha/Note.md');
  assert.deepEqual(calls, ['switch:alpha']);
  assert.equal(app.currentVaultId, 'work');
});

test('v1.35 35.4 rejects clicks with a toast while a vault switch is already in progress', async () => {
  const { app, calls } = createSelectHarness({
    currentVaultId: 'work', targetVaultId: 'alpha', switchInProgress: true
  });
  await app.selectQuickSwitchFile('alpha', 'Alpha/Note.md');
  assert.deepEqual(calls, ['toast:正在切换知识库，请稍候']);
});

// ---------------------------- Index.ets：渲染点接线 ----------------------------

test('v1.35 Index wires the quick switcher to the cross-vault service with registry order and current vault', () => {
  assert.match(indexSource, /import \{ CrossVaultSearchOutcome, CrossVaultSearchService \} from '\.\.\/model\/CrossVaultSearchService';/);
  const renderSite = indexSource.slice(
    indexSource.indexOf('if (this.quickSwitchOpen && this.topView === \'note\') {'),
    indexSource.indexOf('.width(\'100%\')', indexSource.indexOf('QuickSwitcher({'))
  );
  assert.match(renderSite, /vaultCount: this\.vaults\.length/);
  assert.match(renderSite, /currentVaultId: this\.currentVaultId/);
  assert.match(renderSite, /CrossVaultSearchService\.run\(VaultRegistry\.get\(\), this\.vaults,\s*this\.currentVaultId, query, mode, onVaultStart\)/);
  assert.match(renderSite, /cancelAllVaultSearch: \(\): void => \{\s*CrossVaultSearchService\.cancel\(\);/);
  assert.match(renderSite, /onSelect: \(vaultId: string, relPath: string\): void => \{\s*void this\.selectQuickSwitchFile\(vaultId, relPath\);/);
});

test('v1.35 35.5 recent-open recording keys on the vault id captured when the note is opened', () => {
  // loadFile / loadRightFile 打开瞬间取 currentVaultId，recordPaneOpened 用它记录；
  // selectQuickSwitchFile 切库成功后才调用 onSelectFile，因此最近打开天然记入目标库。
  for (const [loader, recorder] of [
    ['  private async loadRightFile(relPath: string): Promise<void> {', 'right'],
    ['  private async loadFile(relPath: string): Promise<void> {', 'left']
  ]) {
    const start = indexSource.indexOf(loader);
    assert.ok(start >= 0, `missing Index loader ${loader}`);
    const site = indexSource.slice(start, indexSource.indexOf('\n  }', start));
    assert.match(site, /const vaultId: string = this\.currentVaultId;/);
    assert.match(site, new RegExp(`this\\.recordPaneOpened\\(vaultId, (?:relPath|path), '${recorder}'\\);`));
  }
  const recordSite = extractIndexMethod('recordPaneOpened(', '\n  }');
  assert.match(recordSite, /store\.record\(vaultId, path\);/);
});

// ---------------------------- QuickSwitcher 结构 ----------------------------

test('v1.35 35.1 defaults to the current-vault scope and only shows the segment with multiple vaults', () => {
  assert.match(quickSwitcherSource, /@State searchScope: string = 'current';/);
  assert.match(quickSwitcherSource, /if \(this\.vaultCount > 1\) \{[\s\S]*?this\.ScopeOption\('current', '当前库'\)[\s\S]*?this\.ScopeOption\('all', '全部库'\)/);
  assert.match(quickSwitcherSource, /@Prop vaultCount: number = 1;/);
  // 单库不显示范围说明行：note 行同样受 vaultCount 门控。
  assert.match(quickSwitcherSource, /if \(this\.vaultCount > 1\) \{\s*Text\(this\.searchScope === 'all'/);
});

test('v1.35 35.3 labels each all-vault row with the vault name and announces vault, note, path', () => {
  assert.match(quickSwitcherSource, /accessibilityText\(group\.vaultId \+ '，' \+ this\.displayName\(hit\.path\) \+ '，' \+ hit\.path\)/);
  assert.match(quickSwitcherSource, /Span\(group\.vaultId\)[\s\S]*?\.fontColor\(\$r\('app\.color\.brand'\)\)/);
  assert.match(quickSwitcherSource, /group\.vaultId \+ \(group\.isCurrentVault \? ' · 当前' : ''\)/);
});

test('v1.35 35.2 quick switcher onSelect always carries the vault id, including current-vault rows', () => {
  assert.match(quickSwitcherSource, /this\.onSelect\(group\.vaultId, hit\.path\);/);
  assert.match(quickSwitcherSource, /this\.onSelect\(this\.currentVaultId, result\.path\);/);
  assert.match(quickSwitcherSource, /this\.onSelect\(this\.currentVaultId, path\);/);
});

test('v1.35 35.6 renders the skipped-vault notice with an expandable vault name list', () => {
  assert.match(quickSwitcherSource, /'已跳过 ' \+ this\.skippedVaultNames\.length\.toString\(\) \+ ' 个暂不可读的库'/);
  assert.match(quickSwitcherSource, /this\.skippedExpanded = !this\.skippedExpanded;/);
  assert.match(quickSwitcherSource, /ForEach\(this\.skippedVaultNames, \(name: string\) => \{/);
});

test('v1.35 all-vault empty states match the specified copy', () => {
  assert.match(quickSwitcherSource, /输入关键词，搜索全部知识库/);
  assert.match(quickSwitcherSource, /全部知识库中没有匹配的笔记/);
  assert.match(quickSwitcherSource, /逐库搜索全部知识库，当前库在前；点开其他库的笔记会切换到该库。/);
});

test('v1.35 token discipline: quick switcher keeps colors and sizes on design tokens', () => {
  assert.doesNotMatch(quickSwitcherSource, /#[0-9a-fA-F]{3,8}\b/);
  assert.doesNotMatch(quickSwitcherSource, /\.fontSize\(\s*\d/);
  assert.doesNotMatch(quickSwitcherSource, /Color\.(?!Transparent)[A-Z]/);
});

// ---------------------------- 原型（35.7） ----------------------------

test('v1.35 35.7 prototype keeps existing quick-search ids and adds the skipped notice', () => {
  for (const id of ['quickSearchDialog', 'quickSearchTitle', 'closeQuickSearch', 'quickSearchInput',
    'quickSearchScope', 'quickSearchResults', 'quickSearchEmpty', 'quickSearchNote']) {
    assert.match(prototypeSource, new RegExp(`id="${id}"`), `missing prototype id ${id}`);
  }
  assert.match(prototypeSource, /id="quickSearchSkipped"/);
  assert.match(prototypeSource, /已跳过 1 个暂不可读的库/);
});

test('v1.35 35.7 prototype toggles the skipped notice only for the all-vault scope', () => {
  assert.match(prototypeSource, /\$\('quickSearchSkipped'\)\.classList\.toggle\('hidden',!\(searchScope==='all'&&libraries\.length>1\)\)/);
});

test('v1.35 35.7 prototype restores the searchScope reproduction parameter once, then resets it', () => {
  assert.match(prototypeSource,
    /let pendingRestore=new URLSearchParams\(window\.location\.search\)\.get\('searchScope'\)==='all'\?'all':'current';/);
  assert.match(prototypeSource, /openQuickSearch=function\(\)\{searchScope=pendingRestore;pendingRestore='current';/);
});
