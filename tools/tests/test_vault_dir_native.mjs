// v1.5 VaultDirNative（目录 URI → fd → Native fdopendir）的源方法级回归。
//
// 这条链路是官方答复（2026-10-31）给的三方唯一通路：ArkTS 侧没有基于 fd 的 readdir，
// 必须 openSync(目录URI) 拿 fd 再交给 Native。这里的 fake 只模拟成功/失败形态，
// 真正的「fdopendir 吃不吃这个 fd」由 XT2 实测回答，Node 侧不假装知道。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
import { readSourceFile } from './lib/source.mjs';

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

function loadModule(source) {
  const code = transformSync(source.replace(/^import .*;\n/gm, ''), {
    loader: 'ts',
    format: 'cjs'
  }).code;
  const context = vm.createContext({
    module: { exports: {} },
    console,
    Array, Object, String, Number, Boolean, JSON, Error, Promise, Map, Set
  });
  vm.runInContext(code, context);
  return context.module.exports;
}

const vault = loadModule(readSourceFile(
  new URL('../../entry/src/main/ets/model/VaultDirNative.ets', import.meta.url)));

const DIR_URI = 'file://docs/storage/Users/currentUser/Download/vault';

/** fake native：按预置结果回答，并记录收到的 fd。 */
function fakeNative(entries, options = {}) {
  const calls = [];
  const make = (fd) => ({
    ok: options.ok !== undefined ? options.ok : true,
    code: options.code !== undefined ? options.code : 0,
    message: options.message !== undefined ? options.message : '',
    entries: typeof entries === 'function' ? entries(fd) : entries
  });
  // 写删改名的返回只有 ok/code/message；不能复用 make()，那会混进遍历的 entries。
  const io = () => ({
    ok: options.ok !== undefined ? options.ok : true,
    code: options.code !== undefined ? options.code : 0,
    message: options.message !== undefined ? options.message : ''
  });
  return {
    calls,
    listDirByFd(fd) {
      calls.push(['flat', fd]);
      return make(fd);
    },
    listDirRecursiveByFd(fd) {
      calls.push(['recursive', fd]);
      return make(fd);
    },
    // ---- 写 / 删 / 改名：答复 Q3-Q4 定的 Native 形态 ----
    readFileByFd(fd, name) {
      calls.push(['read', fd, name]);
      const result = io();
      result.content = options.content !== undefined ? options.content : '# loaded';
      return result;
    },
    writeFileByFd(fd, name, content) {
      calls.push(['write', fd, name, content]);
      return io();
    },
    deleteByFd(fd, name) {
      calls.push(['delete', fd, name]);
      return io();
    },
    renameByFd(fd, oldName, newName) {
      calls.push(['rename', fd, oldName, newName]);
      return io();
    }
  };
}

function fakeFs(options = {}) {
  const opened = [];
  const closed = [];
  return {
    opened,
    closed,
    openDirFd(uri) {
      opened.push(uri);
      if (options.openCode !== undefined) {
        const err = new Error('open failed');
        err.code = options.openCode;
        throw err;
      }
      if (options.failOpen) {
        throw new Error('open failed');
      }
      return options.fd !== undefined ? options.fd : 77;
    },
    closeFd(fd) {
      closed.push(fd);
      if (options.failClose) {
        throw new Error('close failed');
      }
    }
  };
}

test('splitVaultDirEntry distinguishes directories by trailing slash', () => {
  assert.deepEqual(plain(vault.splitVaultDirEntry('Notes/')), { path: 'Notes', isDir: true });
  assert.deepEqual(plain(vault.splitVaultDirEntry('a/b.md')), { path: 'a/b.md', isDir: false });
  // 根目录里的裸文件名不带斜杠，不能被误判成目录
  assert.deepEqual(plain(vault.splitVaultDirEntry('README.md')), { path: 'README.md', isDir: false });
});

test('selectVaultMarkdown keeps .md in any case and skips directories', () => {
  const entries = [
    { path: 'README.md', isDir: false },
    { path: 'notes', isDir: true },
    { path: 'notes/A.MD', isDir: false },
    { path: 'notes/daily.markdown', isDir: false },
    { path: 'notes/skipped.txt', isDir: false }
  ];
  assert.deepEqual(plain(vault.selectVaultMarkdown(entries)),
    ['README.md', 'notes/A.MD', 'notes/daily.markdown']);
});

test('describeVaultDirError maps known errno and keeps unknown ones visible', () => {
  assert.match(vault.describeVaultDirError(2), /ENOENT/);
  assert.match(vault.describeVaultDirError(9), /EBADF/);
  assert.match(vault.describeVaultDirError(13), /EACCES/);
  // 未知 errno 必须把数字带出来，不能吞掉
  assert.match(vault.describeVaultDirError(4242), /4242/);
});

test('scan opens the uri, calls native with the fd, then closes it', () => {
  const native = fakeNative(['a.md', 'notes/']);
  const fs = fakeFs();
  const scanner = new vault.VaultDirectoryScanner(native, fs);

  const result = scanner.scan(DIR_URI, false);

  assert.equal(result.ok, true);
  assert.deepEqual(plain(fs.opened), [DIR_URI]);
  assert.deepEqual(plain(native.calls), [['flat', 77]]);
  // fd 必须被关掉 —— native 用的是 dup 出来的描述符，原始的仍归 ArkTS 管
  assert.deepEqual(plain(fs.closed), [77]);
  assert.deepEqual(plain(result.entries), [
    { path: 'a.md', isDir: false },
    { path: 'notes', isDir: true }
  ]);
});

test('scan(true) routes to the recursive native entrypoint', () => {
  const native = fakeNative(['a.md', 'notes/b.md', 'notes/']);
  const fs = fakeFs();
  const scanner = new vault.VaultDirectoryScanner(native, fs);

  scanner.scan(DIR_URI, true);

  assert.deepEqual(plain(native.calls), [['recursive', 77]]);
});

test('open failure is reported as ok:false with the business error code', () => {
  const fs = fakeFs({ failOpen: true, openCode: 13900002 });
  const scanner = new vault.VaultDirectoryScanner(fakeNative([]), fs);

  const result = scanner.scan(DIR_URI, true);

  assert.equal(result.ok, false);
  assert.equal(result.code, 13900002);
  assert.deepEqual(plain(result.entries), []);
  // 开都没开出来，不该去关一个不存在的 fd
  assert.deepEqual(plain(fs.closed), []);
});

test('partial success still surfaces the entries together with errno', () => {
  const native = fakeNative(['a.md'], { ok: false, code: 13, message: 'Permission denied' });
  const scanner = new vault.VaultDirectoryScanner(native, fakeFs());

  const result = scanner.scan(DIR_URI, true);

  assert.equal(result.ok, false);
  assert.equal(result.code, 13);
  // 关键：拿到东西就必须把东西交出去，不能因为踩到一个无权子目录就判死
  assert.deepEqual(plain(result.entries), [{ path: 'a.md', isDir: false }]);
});

test('close failure does not swallow an otherwise good scan', () => {
  const native = fakeNative(['a.md']);
  const scanner = new vault.VaultDirectoryScanner(native, fakeFs({ failClose: true }));

  const result = scanner.scan(DIR_URI, false);

  assert.equal(result.ok, true);
  assert.equal(result.entries.length, 1);
});

test('errorCodeOf reads BusinessError.code and falls back to -1', () => {
  assert.equal(vault.VaultDirectoryScanner.errorCodeOf({ code: 13900002 }), 13900002);
  assert.equal(vault.VaultDirectoryScanner.errorCodeOf(new Error('boom')), -1);
  assert.equal(vault.VaultDirectoryScanner.errorCodeOf(undefined), -1);
});

// ---- VaultDirFileStore：读写删改全部走 Native，且 fd 生命周期自控 ----
function createStore(native, fs) {
  return new vault.VaultDirFileStore(native, fs);
}

test('store.read returns content and closes the borrowed fd', () => {
  const native = fakeNative([]);
  const fs = fakeFs();
  const result = createStore(native, fs).read(DIR_URI, 'notes/a.md');
  assert.deepEqual(plain(result), { ok: true, code: 0, message: '', content: '# loaded' });
  assert.deepEqual(native.calls, [['read', 77, 'notes/a.md']]);
  assert.deepEqual(fs.opened, [DIR_URI]);
  assert.deepEqual(fs.closed, [77]);
});

test('store.write delegates to native writeFileByFd with relative name', () => {
  const native = fakeNative([]);
  const fs = fakeFs();
  const result = createStore(native, fs).write(DIR_URI, 'a.md', '# new');
  assert.equal(result.ok, true);
  // 关键：传下去的是**相对名**，不是拼出来的 URI —— 官方不保证自拼 URI 可用
  assert.deepEqual(native.calls, [['write', 77, 'a.md', '# new']]);
  assert.deepEqual(fs.closed, [77]);
});

test('store.remove / rename map onto unlinkat / renameat', () => {
  const native = fakeNative([]);
  const store = createStore(native, fakeFs());
  assert.equal(store.remove(DIR_URI, 'old.md').ok, true);
  assert.equal(store.rename(DIR_URI, 'a.md', 'b.md').ok, true);
  assert.deepEqual(native.calls, [['delete', 77, 'old.md'], ['rename', 77, 'a.md', 'b.md']]);
});

test('open failure short-circuits every io call with the errno', () => {
  const native = fakeNative([]);
  const store = createStore(native, fakeFs({ openCode: 13900002 }));
  const read = store.read(DIR_URI, 'a.md');
  assert.equal(read.ok, false);
  assert.equal(read.code, 13900002);
  assert.equal(read.content, '');
  assert.equal(store.write(DIR_URI, 'a.md', 'x').code, 13900002);
  assert.equal(store.remove(DIR_URI, 'a.md').code, 13900002);
  assert.equal(store.rename(DIR_URI, 'a.md', 'b.md').code, 13900002);
  // 开 fd 就失败了，绝不能带着 -1 去调 native
  assert.deepEqual(native.calls, []);
});

test('native write failure surfaces errno instead of throwing', () => {
  const native = fakeNative([], { ok: false, code: 30, message: 'Read-only file system' });
  const result = createStore(native, fakeFs()).write(DIR_URI, 'a.md', 'x');
  assert.equal(result.ok, false);
  assert.equal(result.code, 30);
  // 页面上要能看到人话，不能只给一个数字
  assert.match(result.message, /30|Read-only/);
});
