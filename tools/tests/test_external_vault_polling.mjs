import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));

function methodBody(name, nextMarker) {
  const start = indexSource.indexOf(`  private async ${name}`);
  const end = indexSource.indexOf(nextMarker, start);
  assert.ok(start >= 0 && end > start, `could not find Index.${name}`);
  return indexSource.slice(start, end);
}

test('foreground vault polling scans through VaultAccess and checks open note content', () => {
  const poll = methodBody('pollExternalVault(): Promise<void> {', '\n  private async refreshOpenVaultNote');
  const refresh = methodBody('refreshOpenVaultNote(vaultId: string, path: string, pane: string,',
    '\n  private async clearMissingOpenVaultNote');

  assert.match(indexSource, /const EXTERNAL_VAULT_POLL_MS: number = 5000/);
  assert.match(poll, /accessFor\(vaultId\)\.snapshot\(\)/);
  assert.match(poll, /refreshFileTree\(\)/);
  assert.match(refresh, /NoteService\.tryReadNote/);
  assert.match(refresh, /showStaleSaveConflict/);
  assert.doesNotMatch(poll + refresh, /rootKind/);
  assert.match(indexSource, /onPageHide\(\): void \{\s*this\.stopExternalVaultPolling\(\)/);
  assert.match(indexSource, /onPageShow\(\): void \{\s*this\.startExternalVaultPolling\(\)/);
});
