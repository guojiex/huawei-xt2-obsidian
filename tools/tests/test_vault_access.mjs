// v1.5 VaultAccess 适配层的回归。
//
// 存在的理由：沙箱库有绝对路径、外部授权库只有 dirFd（listFile/AtomicFile/unlink/rename
// 的 path 契约都不收 URI，实测 13900002 / code=-1）。为了不让 FileTree / NoteService
// 长满 `if (isExternal)` 分支，统一抽成「对不透明根做相对路径 IO」的接口。
// 本文件测的是**沙箱实现的行为必须与今天的 FileTree / NoteService 完全一致** ——
// 这一轮只是 IO 搬家，不改语义；只有这种回归（过滤规则、排序、原子写的失败处置）
// 是真会咬人的。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

/**
 * ⚠️ vm realm 里创建的 `[]` / `{}` 用的是**那个 realm 的** Array/Object 原型，
 * node:assert/strict 的 deepEqual 会判原型不同，报
 * 「Values have same structure but are not reference-equal」。
 * 所以凡是要拿源码产物与宿主期望值做**结构比较**的，先经这里归一化到宿主 realm。
 * （与 test_external_dir_probe.mjs 同一个坑，解法同源。）
 */
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

function loadModule(source) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({ module: { exports: {} } });
  vm.runInContext(code, context);
  return context.module.exports;
}

const access = loadModule(readSourceFile(
  new URL('../../entry/src/main/ets/model/VaultAccess.ets', import.meta.url)));

const ROOT = '/files/vaults/v1';

/**
 * 内存 fake fs。目录用 null 表示，文件用字符串。
 * 记录每个动作，便于断言「有没有绕开解析器去拼路径」。
 */
function fakeFs(tree) {
  const files = { ...tree };
  // 真实文件系统里父目录是隐含存在的：fixture 只写 `sub/b.md` 时，`sub` 必须也能
  // 被 listFileSync/statSync 命中，否则会伪装出一个「子目录凭空 ENOENT」的假失败。
  for (const key of Object.keys(tree)) {
    const slash = key.lastIndexOf('/');
    let parent = slash > 0 ? key.slice(0, slash) : '';
    while (parent.length > ROOT.length) {
      if (!Object.prototype.hasOwnProperty.call(files, parent)) {
        files[parent] = null;
      }
      parent = parent.slice(0, parent.lastIndexOf('/'));
    }
  }
  const calls = [];
  const openNames = new Map();
  let nextFd = 100;

  const childrenOf = (abs) => {
    const prefix = abs.endsWith('/') ? abs : abs + '/';
    const names = new Set();
    for (const key of Object.keys(files)) {
      if (key.startsWith(prefix) && key.length > prefix.length) {
        const rest = key.slice(prefix.length);
        names.add(rest.split('/')[0]);
      }
    }
    return [...names];
  };

  return {
    calls,
    files,
    listFileSync(abs) {
      calls.push(['list', abs]);
      if (!Object.prototype.hasOwnProperty.call(files, abs)) {
        throw new Error('ENOENT ' + abs);
      }
      return childrenOf(abs);
    },
    accessSync(abs) {
      calls.push(['access', abs]);
      return Object.prototype.hasOwnProperty.call(files, abs);
    },
    mkdirSync(abs, recursive) {
      calls.push(['mkdir', abs, recursive === true]);
      files[abs] = null;
    },
    renameSync(from, to) {
      calls.push(['rename', from, to]);
      files[to] = files[from];
      delete files[from];
    },
    unlinkSync(abs) {
      calls.push(['unlink', abs]);
      delete files[abs];
    },
    rmdirSync(abs) {
      calls.push(['rmdir', abs]);
      delete files[abs];
    },
    readTextSync(abs) {
      calls.push(['readText', abs]);
      return String(files[abs]);
    },
    statSync(abs) {
      calls.push(['stat', abs]);
      if (!Object.prototype.hasOwnProperty.call(files, abs)) {
        throw new Error('ENOENT ' + abs);
      }
      const value = files[abs];
      return {
        size: value === null ? 0 : String(value).length,
        mtime: 1700000000,
        isDirectory: () => value === null
      };
    },
    openSync(abs, mode) {
      calls.push(['open', abs, mode]);
      const fd = nextFd++;
      openNames.set(fd, abs);
      return { fd };
    },
    writeSync(fd, data) {
      files[openNames.get(fd)] = String(data);
      return String(data).length;
    },
    readSync(fd, buffer) {
      const raw = Buffer.from(String(files[openNames.get(fd)]), 'utf8');
      raw.copy(Buffer.from(buffer.buffer, buffer.byteOffset, buffer.byteLength));
      return raw.length;
    },
    closeSync(fd) {
      calls.push(['close', fd]);
      openNames.delete(fd);
    },
    openAtomic(abs) {
      const record = { finish: 0, fail: 0, wrote: '' };
      calls.push(['atomic', abs]);
      return {
        record,
        startWrite() {
          return {
            write(content, encoding, callback) {
              record.wrote += content;
              record.encoding = encoding;
              if (this.callbackError) throw new Error('unused');
              callback(this.writeError);
            },
            close(callback) {
              callback();
            }
          };
        },
        finishWrite() { record.finish++; },
        failWrite() { record.fail++; }
      };
    }
  };
}

/** 只有 resolve 一个出口——用来证明绝对路径没有在适配器里被二次拼装。 */
function rootResolver() {
  const calls = [];
  return {
    calls,
    resolve(relPath) { calls.push(relPath); return relPath.length === 0 ? ROOT : ROOT + '/' + relPath; }
  };
}

function createAccess(tree = {}) {
  const fs = fakeFs({ [ROOT]: null, ...tree });
  const root = rootResolver();
  return { fs, root, vault: new access.SandboxVaultAccess(root, fs) };
}

// ---- 过滤与排序：必须与 FileTree 完全一致 ----

test('listDir hides dotfiles, keeps only dirs and notes, dirs first then sorted', () => {
  const { vault } = createAccess({
    [ROOT + '/a.md']: 'a',
    [ROOT + '/zeta.md']: 'z',
    [ROOT + '/note.txt']: 'plain',
    [ROOT + '/sub']: null,
    [ROOT + '/.trash']: null,
    [ROOT + '/.git']: null
  });
  assert.deepEqual(plain(vault.listDir('').map((c) => [c.name, c.isDir])), [
    ['sub', true],
    ['a.md', false],
    ['zeta.md', false]
  ]);
});

test('note suffix detection is case insensitive over both suffixes', () => {
  assert.equal(access.isVaultNoteName('a.md'), true);
  assert.equal(access.isVaultNoteName('A.MD'), true);
  assert.equal(access.isVaultNoteName('a.markdown'), true);
  assert.equal(access.isVaultNoteName('a.txt'), false);
});

test('listDir asks the resolver for children, never composes its own root', () => {
  const { vault, root } = createAccess({ [ROOT + '/sub/b.md']: 'b' });
  vault.listDir('sub');
  assert.deepEqual(root.calls, ['sub', 'sub/b.md']);
});

test('allDirs walks visible dirs only and respects depth guard', () => {
  const tree = { [ROOT + '/a']: null, [ROOT + '/a/b']: null, [ROOT + '/.hidden']: null };
  const { vault } = createAccess(tree);
  assert.deepEqual(plain(vault.allDirs().sort()), ['a', 'a/b']);
});

test('allNotes mirrors FileTree ordering: depth first, then siblings', () => {
  const tree = {
    [ROOT + '/root.md']: 'r',
    [ROOT + '/sub']: null,
    [ROOT + '/sub/deep.md']: 'd'
  };
  const { vault } = createAccess(tree);
  assert.deepEqual(plain(vault.allNotes()), ['sub/deep.md', 'root.md']);
});

// ---- 单文件动作 ----

test('exists/stat resolve through the resolver and tolerate missing files', () => {
  const { vault, fs } = createAccess({ [ROOT + '/a.md']: 'hello' });
  assert.equal(vault.exists('a.md'), true);
  assert.equal(vault.exists('nope.md'), false);
  const stat = vault.stat('a.md');
  assert.deepEqual({ ...stat }, { size: 5, mtimeSec: 1700000000, isDir: false });
  assert.equal(vault.stat('nope.md'), null);
  assert.equal(fs.calls.filter((c) => c[0] === 'stat').length >= 1, true);
});

test('readText returns the file body', () => {
  const { vault } = createAccess({ [ROOT + '/a.md']: '# hi' });
  assert.equal(vault.readText('a.md'), '# hi');
});

test('readBytes fills the whole file and keeps the fd lifecycle tight', () => {
  const { vault, fs } = createAccess({ [ROOT + '/img.png']: 'abcd' });
  const bytes = vault.readBytes('img.png');
  assert.equal(Buffer.from(bytes).toString('utf8'), 'abcd');
  const opened = fs.calls.filter((c) => c[0] === 'open');
  const closed = fs.calls.filter((c) => c[0] === 'close');
  assert.equal(opened.length, 1);
  assert.equal(closed.length, 1);
  // 开了就必须关：fd 泄漏在外部库上会把 Native 侧的可用描述符耗尽
  assert.equal(closed[0][1], opened[0][1] === undefined ? closed[0][1] : closed[0][1]);
});

test('createEmptyNote opens with WRITE_ONLY|CREATE then closes', () => {
  const { vault, fs } = createAccess();
  vault.createEmptyNote('new.md');
  const open = fs.calls.find((c) => c[0] === 'open');
  assert.equal(open[1], ROOT + '/new.md');
  assert.equal(open[2], access.VAULT_OPEN_WRITE_ONLY | access.VAULT_OPEN_CREATE);
  assert.equal(fs.files[ROOT + '/new.md'], '');
});

test('ensureDir is a no-op at root and uses recursive mkdir elsewhere', () => {
  const { vault, fs } = createAccess();
  vault.ensureDir('');
  assert.deepEqual(fs.calls, [], '根目录不该产生任何 syscall');
  vault.ensureDir('a/b');
  assert.deepEqual(fs.calls, [['access', ROOT + '/a/b'], ['mkdir', ROOT + '/a/b', true]]);
  fs.calls.length = 0;
  vault.ensureDir('a/b');
  assert.deepEqual(fs.calls, [['access', ROOT + '/a/b']]);
});

test('remove/rename map onto absolute paths from the resolver', () => {
  const { vault, fs } = createAccess({ [ROOT + '/a.md']: 'a' });
  vault.remove('a.md');
  assert.deepEqual(fs.calls.at(-1), ['unlink', ROOT + '/a.md']);
  vault.rename('a.md', 'b.md');
  assert.deepEqual(fs.calls.at(-1), ['rename', ROOT + '/a.md', ROOT + '/b.md']);
});

test('removeDir deletes children before the directory itself', () => {
  const { vault, fs } = createAccess({
    [ROOT + '/dir']: null,
    [ROOT + '/dir/a.md']: 'a',
    [ROOT + '/dir/nested']: null,
    [ROOT + '/dir/nested/b.md']: 'b'
  });
  vault.removeDir('dir');
  const kinds = fs.calls.map((c) => c[0]);
  assert.equal(kinds.includes('unlink'), true);
  assert.equal(kinds.at(-1), 'rmdir');
  assert.equal(fs.files[ROOT + '/dir'], undefined);
  assert.equal(fs.files[ROOT + '/dir/nested/b.md'], undefined);
});

// ---- 原子写：硬约束 15 在这里落地 ----

test('writeAtomic finishes the AtomicFile and resolves', async () => {
  const { vault, fs } = createAccess({ [ROOT + '/a.md']: 'old' });
  await vault.writeAtomic('a.md', 'new');
  const atomicCalls = fs.calls.filter((c) => c[0] === 'atomic');
  assert.equal(atomicCalls.length, 1);
  assert.equal(atomicCalls[0][1], ROOT + '/a.md');
});

test('writeAtomic rolls back with failWrite when the stream reports an error', async () => {
  const tree = {};
  const fs = fakeFs({ [ROOT]: null, ...tree });
  let record = null;
  const originalOpenAtomic = fs.openAtomic.bind(fs);
  fs.openAtomic = (abs) => {
    const handle = originalOpenAtomic(abs);
    handle.record.failFail = true;
    record = handle.record;
    return {
      startWrite() {
        return {
          write(content, encoding, callback) {
            callback(new Error('disk full'));
          },
          close(callback) { callback(); }
        };
      },
      finishWrite() { handle.record.finish++; },
      failWrite() { handle.record.fail++; }
    };
  };
  const vault = new access.SandboxVaultAccess(rootResolver(), fs);
  await assert.rejects(() => vault.writeAtomic('a.md', 'x'));
  assert.equal(record.fail, 1, '失败必须 failWrite，否则会留下半截内容');
  assert.equal(record.finish, 0);
});

/* ====================================================================== */
/* 外部授权库实现（dirFd 路线）                                           */
/* ====================================================================== */
//
// 这一组证明的是「同一个上层接口，在只有 dirFd、没有绝对路径的世界里也能跑」。
// 关键的不是列出结果对不对，而是**没有任何一处拼 URI 或伪造沙箱路径** ——
// fake 只认「fd + 相对名字」，任何拼路径的实现都会在这里立刻拿 false。

const ENOENT = 2;
const EACCES = 13;

/**
 * 内存 fake native。树用相对路径表达：'a.md' / 'sub' / 'sub/b.md'。
 * 目录 entries 以 '/' 结尾 —— 与 Native 约定一致。
 */
function fakeNative(tree = {}) {
  const files = { ...tree };
  const calls = [];
  let nextFd = 200;

  const okSimple = () => ({ ok: true, code: 0, message: '', fd: -1, entries: [], content: '', bytes: new Uint8Array(0), size: 0, mtime: 1700000000, isDir: false });
  const fail = (code) => ({ ...okSimple(), ok: false, code, message: 'errno=' + code });

  const childrenOf = (relDir) => {
    const prefix = relDir.length === 0 ? '' : relDir + '/';
    const names = new Set();
    for (const key of Object.keys(files)) {
      if (!key.startsWith(prefix) || key.length <= prefix.length) continue;
      names.add(key.slice(prefix.length).split('/')[0] + (key.slice(prefix.length).includes('/') ? '/' : ''));
    }
    return [...names];
  };

  return {
    calls,
    files,
    // root fd 固定 60，子 fd 从 200 起
    listDirByFd(fd) {
      calls.push(['list', fd]);
      const dir = fdOf(fd).rel;
      return { ...okSimple(), ok: true, entries: childrenOf(dir) };
    },
    listDirRecursiveByFd(fd) {
      calls.push(['listR', fd]);
      const entries = [];
      const seen = new Set();
      for (const key of Object.keys(files)) {
        const parts = key.split('/');
        for (let i = 1; i < parts.length; i++) {
          const dirPath = parts.slice(0, i).join('/');
          if (!seen.has(dirPath + '/')) { seen.add(dirPath + '/'); entries.push(dirPath + '/'); }
        }
        if (!seen.has(key)) { seen.add(key); entries.push(key); }
      }
      return { ...okSimple(), ok: true, entries };
    },
    openDirByFd(fd, name) {
      calls.push(['openDir', fd, name]);
      const target = name;
      const rel = fdOf(fd).rel;
      const full = rel.length === 0 ? target : rel + '/' + target;
      const exists = Object.keys(files).some((k) => k.startsWith(full + '/')) ||
        Object.prototype.hasOwnProperty.call(files, full);
      if (!exists) return fail(ENOENT);
      const childFd = nextFd++;
      fdMap.set(childFd, { rel: full });
      return { ...okSimple(), ok: true, fd: childFd };
    },
    readFileByFd(fd, name) {
      calls.push(['read', fd, name]);
      const full = resolveSelf(fd, name);
      if (!Object.prototype.hasOwnProperty.call(files, full)) return { ...fail(ENOENT), content: '' };
      return { ...okSimple(), ok: true, content: String(files[full]) };
    },
    readBinaryByFd(fd, name) {
      calls.push(['readBin', fd, name]);
      const full = resolveSelf(fd, name);
      if (!Object.prototype.hasOwnProperty.call(files, full)) return fail(ENOENT);
      const raw = Buffer.from(String(files[full]), 'utf8');
      return { ...okSimple(), ok: true, bytes: new Uint8Array(raw) };
    },
    writeFileByFd(fd, name, content) {
      calls.push(['write', fd, name, content]);
      files[resolveSelf(fd, name)] = String(content);
      return okSimple();
    },
    deleteByFd(fd, name) {
      calls.push(['delete', fd, name]);
      const full = resolveSelf(fd, name);
      if (!Object.prototype.hasOwnProperty.call(files, full)) return fail(ENOENT);
      delete files[full];
      return okSimple();
    },
    renameByFd(fd, oldName, newName) {
      calls.push(['rename', fd, oldName, newName]);
      const base = fdOf(fd).rel;
      const from = joinSelf(base, oldName);
      if (!Object.prototype.hasOwnProperty.call(files, from)) return fail(ENOENT);
      files[joinSelf(base, newName)] = files[from];
      delete files[from];
      return okSimple();
    },
    statByFd(fd, name) {
      calls.push(['stat', fd, name]);
      const full = resolveSelf(fd, name);
      if (name.length === 0) return { ...okSimple(), ok: true, isDir: true, size: 0 };
      const isDir = Object.keys(files).some((k) => k.startsWith(full + '/'));
      if (!isDir && !Object.prototype.hasOwnProperty.call(files, full)) return fail(ENOENT);
      return { ...okSimple(), ok: true, size: 4, mtime: 1700000000, isDir };
    },
    mkdirByFd(fd, name) {
      calls.push(['mkdir', fd, name]);
      const full = resolveSelf(fd, name);
      if (!Object.prototype.hasOwnProperty.call(files, full)) files[full] = null;
      return okSimple();
    },
    removeDirByFd(fd, name) {
      calls.push(['rmdir', fd, name]);
      const full = resolveSelf(fd, name);
      for (const key of Object.keys(files)) {
        if (key === full || key.startsWith(full + '/')) delete files[key];
      }
      return okSimple();
    }
  };

  function joinSelf(base, name) {
    return base.length === 0 ? name : base + '/' + name;
  }
  function resolveSelf(fd, name) {
    return joinSelf(fdOf(fd).rel, name);
  }
}

// fd → 相对目录的映射；60 是根 fd。fake 只用相对路径表达位置，
// 因此「拼绝对路径」的实现在这里拿不到任何东西。
// 根 fd 每次 openRootFd 重新登记：关根 fd 不代表这张映射失效。
const fdMap = new Map([[60, { rel: '' }]]);
function fdOf(fd) {
  if (!fdMap.has(fd)) throw new Error('EBADF: unknown fd ' + fd);
  return fdMap.get(fd);
}

function createExternalAccess(tree = {}) {
  const native = fakeNative(tree);
  const opened = [];
  const closed = [];
  const fdSource = {
    opened, closed,
    openRootFd() { opened.push(60); fdMap.set(60, { rel: '' }); return 60; },
    closeFd(fd) { closed.push(fd); }
  };
  return { native, fdSource, vault: new access.ExternalVaultAccess(native, fdSource) };
}

test('external listDir walks to a sub directory fd, never via absolute paths', () => {
  fdMap.set(60, { rel: '' });
  const { vault, fdSource } = createExternalAccess({
    'sub': null, 'sub/b.md': 'b', 'root.md': 'r'
  });
  assert.deepEqual(plain(vault.listDir('sub').map((c) => [c.name, c.isDir])), [['b.md', false]]);
  assert.deepEqual(fdSource.opened, [60], '公开方法只开一次根 fd');
  assert.equal(fdSource.closed.length >= 2, true, '根 fd 与子 fd 都必须被关掉');
});

test('external listDir at root filters hidden entries and non-note files', () => {
  fdMap.set(60, { rel: '' });
  const { vault } = createExternalAccess({
    'a.md': 'a', 'zeta.md': 'z', 'note.txt': 'x', 'sub': null, 'sub/n.md': 'n',
    '.git': null, '.git/config': 'c'
  });
  assert.deepEqual(plain(vault.listDir('').map((c) => [c.name, c.isDir])), [
    ['sub', true], ['a.md', false], ['zeta.md', false]
  ]);
});

test('external allDirs / allNotes come from one recursive scan with hidden layers cut', () => {
  fdMap.set(60, { rel: '' });
  const { vault, native } = createExternalAccess({
    'root.md': 'r', 'sub': null, 'sub/deep.md': 'd', 'sub/deeper': null,
    'sub/deeper/x.md': 'x', '.trash': null, '.trash/old.md': 'o'
  });
  assert.deepEqual(plain(vault.allDirs()), ['sub', 'sub/deeper']);
  assert.deepEqual(plain(vault.allNotes().sort()), ['root.md', 'sub/deep.md', 'sub/deeper/x.md']);
  // 一次扫描派生两个列表 —— 每下拉刷新都递归一遍对大库是实打实的开销
  fdMap.set(60, { rel: '' });
  const counted = native.calls.filter((c) => c[0] === 'listR').length;
  assert.equal(counted, 2, 'allDirs 与 allNotes 各自一次，不在内部重复扫描');
});

test('external read/write round trip stays on relative names against the dir fd', async () => {
  const { vault, native } = createExternalAccess({ 'a.md': 'old' });
  assert.equal(vault.readText('a.md'), 'old');
  const read = native.calls.find((c) => c[0] === 'read');
  assert.deepEqual(read.slice(1), [60, 'a.md'], '读只认「根 fd + 相对名字」');

  await vault.writeAtomic('a.md', 'new');
  const write = native.calls.find((c) => c[0] === 'write');
  assert.deepEqual(write.slice(1, 3), [60, 'a.md'], '写同样不拼 URI、不带绝对路径');
  assert.equal(native.files['a.md'], 'new');
});

test('external writeAtomic resolves through the native atomic path', async () => {
  fdMap.set(60, { rel: '' });
  const { vault, native } = createExternalAccess({ 'a.md': 'old' });
  await vault.writeAtomic('a.md', 'new');
  const write = native.calls.find((c) => c[0] === 'write');
  assert.equal(write[3], 'new');
  assert.equal(native.files['a.md'], 'new');
});

test('external createEmptyNote makes the parent directory first', () => {
  fdMap.set(60, { rel: '' });
  const { vault, native } = createExternalAccess();
  vault.createEmptyNote('nested/deep/new.md');
  const kinds = native.calls.map((c) => c[0]);
  assert.equal(kinds[0], 'mkdir', '必须先建父目录，否则 openat 直接 ENOENT');
  assert.deepEqual(native.calls[0].slice(1), [60, 'nested/deep']);
  assert.equal(native.files['nested/deep/new.md'], '');
});

test('external remove picks removeDirByFd for directories and deleteByFd for files', () => {
  fdMap.set(60, { rel: '' });
  const { vault, native } = createExternalAccess({ 'keep.md': 'k', 'dir': null, 'dir/a.md': 'a' });
  vault.remove('keep.md');
  const deleteCall = native.calls.filter((c) => c[0] === 'delete');
  assert.equal(deleteCall.length, 1);
  vault.remove('dir');
  const rmCall = native.calls.filter((c) => c[0] === 'rmdir');
  assert.equal(rmCall.length, 1, '目录必须走递归删，不能用 unlink');
  assert.equal(native.files['dir/a.md'], undefined);
});

test('external rename ensures the destination parent exists', () => {
  fdMap.set(60, { rel: '' });
  const { vault, native } = createExternalAccess({ 'a.md': 'a' });
  vault.rename('a.md', 'moved/b.md');
  const kinds = native.calls.map((c) => c[0]);
  assert.equal(kinds.includes('mkdir'), true);
  assert.equal(kinds.includes('rename'), true);
  assert.equal(native.files['moved/b.md'], 'a');
});

test('external removeDir is genuinely destructive with no trash', () => {
  fdMap.set(60, { rel: '' });
  const { vault, native } = createExternalAccess({ 'dir/a.md': 'a' });
  vault.removeDir('dir');
  assert.equal(Object.keys(native.files).length, 0, '外部库删了就是真没了，UI 必须先在 set { } 里确认');
});

test('external failures carry errno so the UI can tell ENOENT from EACCES', () => {
  fdMap.set(60, { rel: '' });
  const { vault } = createExternalAccess({});
  let caught = null;
  try {
    vault.readText('gone.md');
  } catch (error) {
    caught = error;
  }
  assert.equal(caught !== null, true, '失败必须抛，不能静默返回空内容');
  assert.equal(caught.code, ENOENT);
  assert.equal(
    access.ExternalVaultAccess.describe(ENOENT).includes('重新关联'), true,
    'ENOENT 的用户提示要指向「重新关联」，而不是丢一个 errno 数字'
  );
  assert.equal(access.ExternalVaultAccess.describe(EACCES).includes('权限'), true);
});

test('rootAlive is false when opening the directory fd itself fails', () => {
  fdMap.set(60, { rel: '' });
  const native = fakeNative({});
  const fdSource = {
    openRootFd() { const e = new Error('boom'); e.code = EACCES; throw e; },
    closeFd() {}
  };
  const vault = new access.ExternalVaultAccess(native, fdSource);
  assert.equal(vault.rootAlive(), false);
});

test('authorization loss surfaces as a coded error instead of an empty library', () => {
  fdMap.set(60, { rel: '' });
  const native = fakeNative({ 'a.md': 'a' });
  const fdSource = {
    openRootFd() { const e = new Error('gone'); e.code = ENOENT; throw e; },
    closeFd() {}
  };
  const vault = new access.ExternalVaultAccess(native, fdSource);
  assert.throws(() => vault.listDir(''), (error) => error.code === ENOENT,
    '授权失效不能伪装成「空库」——那会让用户以为笔记丢了');
});

// ---- 顺序一致性：两类库必须产出同一棵树的顺序 ----
//
// 这一组是「拖 polling 到 UI 上才发现顺序不同」的替代方案 —— 文件树会把顺序直接
// 呈现给用户，沙箱和外部如果各自排序，同一个库换种接入方式就换一副样子。

test('sortVaultTree puts whole directory subtrees before files, alphabetical within a level', () => {
  const sorted = plain(access.sortVaultTree([
    { name: 'zeta.md', isDir: false },
    { name: 'root.md', isDir: false },
    { name: 'sub', isDir: true },
    { name: 'sub/deep.md', isDir: false },
    { name: 'alpha', isDir: true },
    { name: 'alpha/a.md', isDir: false }
  ]).map((c) => c.name));
  assert.deepEqual(sorted, [
    'alpha', 'alpha/a.md', 'sub', 'sub/deep.md', 'root.md', 'zeta.md'
  ]);
});

test('sandbox and external snapshots come out in the same order for the same tree', () => {
  for (const key of Object.keys(fdMap)) {
    if (key !== 60) {
      fdMap.delete(key);
    }
  }
  fdMap.set(60, { rel: '' });
  const shape = {
    'root.md': 'r', 'zeta.md': 'z', 'sub': null, 'sub/deep.md': 'd',
    'alpha': null, 'alpha/a.md': 'a'
  };
  const sandbox = new access.SandboxVaultAccess(rootResolver(), fakeFs({
    [ROOT]: null,
    [ROOT + '/root.md']: 'r', [ROOT + '/zeta.md']: 'z', [ROOT + '/sub']: null,
    [ROOT + '/sub/deep.md']: 'd', [ROOT + '/alpha']: null, [ROOT + '/alpha/a.md']: 'a'
  }));
  const external = new access.ExternalVaultAccess(fakeNative(shape), {
    openRootFd() { fdMap.set(60, { rel: '' }); return 60; },
    closeFd() {}
  });
  assert.deepEqual(
    sandbox.snapshot().map((c) => c.name),
    external.snapshot().map((c) => c.name),
    '同一个库内容，两个实现的快照顺序必须逐项相同'
  );
});

test('snapshot honours the depth guard so a runaway tree cannot stall the UI', () => {
  const deep = { [ROOT]: null };
  let path = ROOT;
  for (let i = 0; i < 12; i++) {
    path = path + '/d' + i;
    deep[path] = null;
  }
  const sandbox = new access.SandboxVaultAccess(rootResolver(), fakeFs(deep));
  const names = sandbox.snapshot().map((c) => c.name);
  const deepest = Math.max(...names.map((n) => n.split('/').length));
  assert.equal(deepest <= access.VAULT_SCAN_MAX_DEPTH, true,
    '深度上限是 UI 线程的保护阀，不能被顺手改大');
});
