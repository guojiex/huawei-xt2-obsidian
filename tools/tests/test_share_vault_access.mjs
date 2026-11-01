import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const noteShare = fs.readFileSync(new URL('../../entry/src/main/ets/model/NoteShareService.ets', import.meta.url), 'utf8');
const archiveShare = fs.readFileSync(new URL('../../entry/src/main/ets/model/ShareArchiveService.ets', import.meta.url),
  'utf8');
const nativeVault = fs.readFileSync(new URL('../../native/vaultdir_napi/src/vaultdir_napi.c', import.meta.url), 'utf8');

test('single-note sharing reads image metadata and bytes through VaultAccess', () => {
  const start = noteShare.indexOf('static async prepareNote(');
  const end = noteShare.indexOf('\n  /** 递归清理', start);
  assert.ok(start >= 0 && end > start);
  const method = noteShare.slice(start, end);
  assert.match(method, /registry\.accessFor\(vaultId\)/);
  assert.match(method, /vaultAccess\.stat\(sourcePath\)/);
  assert.match(method, /vaultAccess\.readBytes\(/);
  assert.doesNotMatch(method, /registry\.absoluteIn\(/);
});

test('archive sharing enumerates and reads formal files through the same access layer', () => {
  assert.match(archiveShare, /registry\.accessFor\(vaultId\)/);
  assert.match(archiveShare, /vaultAccess\.listAll\(directory\)/);
  assert.match(archiveShare, /vaultAccess\.readText\(path\)/);
  assert.match(archiveShare, /vaultAccess\.readBytes\(/);
  assert.doesNotMatch(archiveShare, /registry\.absoluteIn\(/);
  assert.doesNotMatch(archiveShare, /registry\.vaultDirOf\(/);
});

test('Native external paths walk every parent with O_NOFOLLOW and reject dot segments', () => {
  assert.match(nativeVault, /static int vaultdir_open_parent\(/);
  assert.match(nativeVault, /openat\(current, segment, O_RDONLY \| O_DIRECTORY \| O_CLOEXEC \| O_NOFOLLOW\)/);
  assert.match(nativeVault, /strcmp\(segment, "\.\."\) == 0/);
  assert.match(nativeVault, /AT_SYMLINK_NOFOLLOW/);
});

test('Native attachment creation uses O_EXCL and does not replace an existing file', () => {
  assert.match(nativeVault, /openat\(parent_fd, leaf, O_CREAT \| O_EXCL \| O_WRONLY \| O_CLOEXEC/);
});
