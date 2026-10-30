import { fileIo } from '@kit.CoreFileKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { afterAll, beforeAll, describe, expect, it } from '@ohos/hypium';
import nativeGit2, { Git2RepositoryState } from 'libgit2_napi.so';
import { VaultRegistry } from '../../../main/ets/model/VaultRegistry';

interface Git2NativeTarget {
  id: string;
  path: string;
}

const FIXTURE_URL: string = 'http://127.0.0.1:19439/fixture.git';
const FIXTURE_USERNAME: string = 'fixture-user';
const FIXTURE_PASSWORD: string = 'fixture-password';
const FIXTURE_BEARER_TOKEN: string = 'fixture-bearer-token';
const PUBLIC_HTTPS_FIXTURE_URL: string = 'https://github.com/git-fixtures/basic.git';
const EMPTY_SHA256: string = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
const SHA256_ROUND_CONSTANTS: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
const SHA256_INITIAL_STATE: number[] = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];
let registry: VaultRegistry;
let serial: number = 0;
const testVaultIds: string[] = [];

function newTarget(label: string): Git2NativeTarget {
  serial++;
  const id: string = registry.uniqueVaultId('git2_probe_' + label + '_' + Date.now().toString() + '_' + serial.toString(), '');
  testVaultIds.push(id);
  return { id: id, path: registry.vaultDirOf(id) };
}

function removeTree(path: string): void {
  if (!fileIo.accessSync(path)) return;
  const stat: fileIo.Stat = fileIo.statSync(path);
  if (!stat.isDirectory()) {
    fileIo.unlinkSync(path);
    return;
  }
  const names: string[] = fileIo.listFileSync(path);
  for (let i: number = 0; i < names.length; i++) {
    removeTree(path + '/' + names[i]);
  }
  fileIo.rmdirSync(path);
}

function rotateRight(value: number, amount: number): number {
  return (value >>> amount) | (value << (32 - amount));
}

function sha256Bytes(bytes: Uint8Array): string {
  const bitLength: number = bytes.length * 8;
  const paddedLength: number = Math.ceil((bytes.length + 9) / 64) * 64;
  const padded: Uint8Array = new Uint8Array(paddedLength);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  const highBits: number = Math.floor(bitLength / 0x100000000);
  const lowBits: number = bitLength >>> 0;
  for (let i: number = 0; i < 4; i++) {
    padded[paddedLength - 8 + i] = (highBits >>> (24 - i * 8)) & 0xff;
    padded[paddedLength - 4 + i] = (lowBits >>> (24 - i * 8)) & 0xff;
  }

  const state: Uint32Array = new Uint32Array(SHA256_INITIAL_STATE);
  const words: Uint32Array = new Uint32Array(64);
  for (let offset: number = 0; offset < paddedLength; offset += 64) {
    for (let i: number = 0; i < 16; i++) {
      const index: number = offset + i * 4;
      words[i] = ((padded[index] << 24) | (padded[index + 1] << 16) |
        (padded[index + 2] << 8) | padded[index + 3]) >>> 0;
    }
    for (let i: number = 16; i < 64; i++) {
      const left: number = words[i - 15];
      const right: number = words[i - 2];
      const sigma0: number = rotateRight(left, 7) ^ rotateRight(left, 18) ^ (left >>> 3);
      const sigma1: number = rotateRight(right, 17) ^ rotateRight(right, 19) ^ (right >>> 10);
      words[i] = (words[i - 16] + sigma0 + words[i - 7] + sigma1) >>> 0;
    }

    let a: number = state[0];
    let b: number = state[1];
    let c: number = state[2];
    let d: number = state[3];
    let e: number = state[4];
    let f: number = state[5];
    let g: number = state[6];
    let h: number = state[7];
    for (let i: number = 0; i < 64; i++) {
      const sum1: number = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const choose: number = (e & f) ^ (~e & g);
      const first: number = (h + sum1 + choose + SHA256_ROUND_CONSTANTS[i] + words[i]) >>> 0;
      const sum0: number = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const majority: number = (a & b) ^ (a & c) ^ (b & c);
      const second: number = (sum0 + majority) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + first) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (first + second) >>> 0;
    }
    state[0] = (state[0] + a) >>> 0;
    state[1] = (state[1] + b) >>> 0;
    state[2] = (state[2] + c) >>> 0;
    state[3] = (state[3] + d) >>> 0;
    state[4] = (state[4] + e) >>> 0;
    state[5] = (state[5] + f) >>> 0;
    state[6] = (state[6] + g) >>> 0;
    state[7] = (state[7] + h) >>> 0;
  }

  const digits: string = '0123456789abcdef';
  let hex: string = '';
  for (let i: number = 0; i < state.length; i++) {
    const word: number = state[i];
    for (let shift: number = 28; shift >= 0; shift -= 4) {
      hex += digits.charAt((word >>> shift) & 0x0f);
    }
  }
  return hex;
}

async function sha256(path: string): Promise<string> {
  const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  let bytes: Uint8Array;
  try {
    const stat: fileIo.Stat = fileIo.statSync(path);
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    const count: number = fileIo.readSync(file.fd, buffer);
    if (count !== stat.size) throw new Error('test file read was incomplete');
    bytes = new Uint8Array(buffer);
  } finally {
    fileIo.closeSync(file);
  }
  return sha256Bytes(bytes);
}

function writeText(path: string, value: string): void {
  const file: fileIo.File = fileIo.openSync(path,
    fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, value);
  } finally {
    fileIo.closeSync(file);
  }
}

async function fixturePackSha256(): Promise<string> {
  const request: http.HttpRequest = http.createHttp();
  try {
    const response: http.HttpResponse = await request.request(
      'http://127.0.0.1:19439/__fixture/pack-sha256', {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
      });
    if (response.responseCode !== 200 || typeof response.result !== 'string') {
      throw new Error('fixture pack checksum endpoint failed');
    }
    return response.result;
  } finally {
    request.destroy();
  }
}

function packFiles(path: string): string[] {
  const packDirectory: string = path + '/.git/objects/pack';
  const names: string[] = fileIo.listFileSync(packDirectory);
  const packs: string[] = [];
  for (let i: number = 0; i < names.length; i++) {
    if (names[i].endsWith('.pack')) packs.push(packDirectory + '/' + names[i]);
  }
  return packs;
}

export default function git2NativeTest() {
  describe('Git2Native', () => {
    it('computes SHA-256 checksums for known bytes', 0, (): void => {
      expect(sha256Bytes(new Uint8Array(0))).assertEqual(EMPTY_SHA256);
      expect(sha256Bytes(new Uint8Array([0x61, 0x62, 0x63])))
        .assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    it('loads libgit2 and reports HTTPS support', 0, (): void => {
      expect(nativeGit2.getVersion().length > 0).assertTrue();
      expect(nativeGit2.getFeatures().https).assertTrue();
      expect(nativeGit2.getFeatures().threads).assertTrue();
    });

    it('clones an authenticated isolated repository on xt2 and verifies bytes and status', 0,
      async (): Promise<void> => {
        const target = newTarget('authenticated');
        let progressCount: number = 0;
        let eventLoopResponsive: boolean = false;
        const heartbeat: Promise<void> = new Promise<void>((resolve): void => {
          setTimeout((): void => {
            eventLoopResponsive = true;
            resolve();
          }, 0);
        });
        let cloneFinished: boolean = false;
        try {
          const expectedPackSha256: string = await fixturePackSha256();
          const clonePromise: Promise<string> = nativeGit2.clone({
            url: FIXTURE_URL,
            targetPath: target.path,
            branch: 'xt2',
            username: FIXTURE_USERNAME,
            password: FIXTURE_PASSWORD,
            onProgress: (): void => {
              progressCount++;
            },
          }).then((path: string): string => {
            cloneFinished = true;
            return path;
          });
          await heartbeat;
          expect(eventLoopResponsive).assertTrue();
          expect(cloneFinished).assertFalse();
          await clonePromise;
          expect(progressCount > 0).assertTrue();

          const state: Git2RepositoryState = nativeGit2.getRepositoryState(target.path);
          expect(state.branch).assertEqual('xt2');
          expect(state.clean).assertTrue();
          expect(state.statusEntryCount).assertEqual(0);
          expect(state.packFileCount > 0).assertTrue();

          const packs: string[] = packFiles(target.path);
          expect(packs.length).assertEqual(1);
          expect(await sha256(packs[0])).assertEqual(expectedPackSha256);

          expect(await sha256(registry.absoluteIn(target.id, '笔记/中文.md')))
            .assertEqual('7ae8a1d46c0c1de49ebdc0194636ba1fac12609ff6a15d6cb7eafbb0dc3532bf');
          expect(await sha256(registry.absoluteIn(target.id, '空文件.bin'))).assertEqual(EMPTY_SHA256);
          expect(await sha256(registry.absoluteIn(target.id, '50_Assets/小图.png')))
            .assertEqual('52ccca2f91b824d33d9141718e1afaf1466b4b54af76301266ee6a3e789d378b');
          expect(await sha256(registry.absoluteIn(target.id, 'git-object.bin')))
            .assertEqual('d62cc92f4535f9bb245d4fccfe902f332c555b0a79dd858fcf34f71699825b31');
          expect(await sha256(registry.absoluteIn(target.id, 'progress-probe.bin')))
            .assertEqual('b640ef8d06e11763a7b12c4bfc61fa7be9f6cd109d89cb7d1b91490f1db06133');
        } finally {
          removeTree(target.path);
        }
      });

    it('stages, commits, fetches and pushes without changing workspace bytes', 0,
      async (): Promise<void> => {
        const current = newTarget('sync_current');
        const stale = newTarget('sync_stale');
        const remoteCheck = newTarget('sync_remote_check');
        const noteRelPath: string = '笔记/中文.md';
        const notePath: string = registry.absoluteIn(current.id, noteRelPath);
        const staleNotePath: string = registry.absoluteIn(stale.id, noteRelPath);
        let committedOid: string = '';
        try {
          await nativeGit2.clone({
            url: FIXTURE_URL,
            targetPath: current.path,
            branch: 'xt2',
            username: FIXTURE_USERNAME,
            password: FIXTURE_PASSWORD,
          });
          await nativeGit2.clone({
            url: FIXTURE_URL,
            targetPath: stale.path,
            branch: 'xt2',
            username: FIXTURE_USERNAME,
            password: FIXTURE_PASSWORD,
          });

          writeText(notePath, '# 已编辑\n工作区内容保持原字节。\n');
          const expectedHash: string = await sha256(notePath);
          const trashDir: string = registry.trashDirOf(current.id);
          if (!fileIo.accessSync(trashDir)) {
            fileIo.mkdirSync(trashDir);
          }
          writeText(trashDir + '/ignored.md', 'do not stage');
          writeText(trashDir + '/tracked.md', 'local trash change must stay local\n');

          const indexLockPath: string = current.path + '/.git/index.lock';
          const indexPath: string = current.path + '/.git/index';
          const indexHashBeforeFailure: string = await sha256(indexPath);
          fileIo.mkdirSync(indexLockPath);
          let writeFailed: boolean = false;
          try {
            await nativeGit2.gitAction({ operation: 'stage', repositoryPath: current.path });
          } catch {
            writeFailed = true;
          } finally {
            fileIo.rmdirSync(indexLockPath);
          }
          expect(writeFailed).assertTrue();
          expect(await sha256(indexPath)).assertEqual(indexHashBeforeFailure);
          expect(await sha256(notePath)).assertEqual(expectedHash);
          expect(nativeGit2.getRepositoryState(current.path).statusEntryCount).assertEqual(1);

          await nativeGit2.gitAction({ operation: 'stage', repositoryPath: current.path });
          await nativeGit2.gitAction({ operation: 'stage', repositoryPath: current.path });
          const stagedState: Git2RepositoryState = nativeGit2.getRepositoryState(current.path);
          expect(stagedState.clean).assertFalse();
          expect(stagedState.statusEntryCount).assertEqual(1);

          committedOid = await nativeGit2.gitAction({
            operation: 'commit',
            repositoryPath: current.path,
            message: 'test: update note',
            authorName: 'Isolated Fixture',
            authorEmail: 'fixture@example.invalid',
          });
          expect(await sha256(notePath)).assertEqual(expectedHash);
          const committedState: Git2RepositoryState = nativeGit2.getRepositoryState(current.path);
          expect(committedState.clean).assertTrue();
          expect(committedState.aheadCount).assertEqual(1);

          let authFailed: boolean = false;
          try {
            await nativeGit2.gitAction({
              operation: 'push',
              repositoryPath: current.path,
              bearerToken: 'incorrect-test-token',
            });
          } catch {
            authFailed = true;
          }
          expect(authFailed).assertTrue();
          expect(await sha256(notePath)).assertEqual(expectedHash);

          const pushedOid: string = await nativeGit2.gitAction({
            operation: 'push',
            repositoryPath: current.path,
            bearerToken: FIXTURE_BEARER_TOKEN,
          });
          expect(pushedOid).assertEqual(committedOid);
          expect(nativeGit2.getRepositoryState(current.path).aheadCount).assertEqual(0);
          expect(await nativeGit2.gitAction({
            operation: 'push',
            repositoryPath: current.path,
            bearerToken: FIXTURE_BEARER_TOKEN,
          })).assertEqual(committedOid);
          expect(await sha256(notePath)).assertEqual(expectedHash);

          expect(await nativeGit2.gitAction({
            operation: 'fetch',
            repositoryPath: stale.path,
            username: FIXTURE_USERNAME,
            password: FIXTURE_PASSWORD,
          })).assertEqual('fetched');
          const fetchedState: Git2RepositoryState = nativeGit2.getRepositoryState(stale.path);
          expect(fetchedState.behindCount > 0).assertTrue();

          writeText(staleNotePath, '# 远端前的本地更改\n不应强推覆盖远端。\n');
          const staleHash: string = await sha256(staleNotePath);
          await nativeGit2.gitAction({ operation: 'stage', repositoryPath: stale.path });
          await nativeGit2.gitAction({
            operation: 'commit',
            repositoryPath: stale.path,
            message: 'test: stale local update',
            authorName: 'Isolated Fixture',
            authorEmail: 'fixture@example.invalid',
          });
          let conflictRejected: boolean = false;
          try {
            await nativeGit2.gitAction({
              operation: 'push',
              repositoryPath: stale.path,
              username: FIXTURE_USERNAME,
              password: FIXTURE_PASSWORD,
            });
          } catch {
            conflictRejected = true;
          }
          expect(conflictRejected).assertTrue();
          expect(await sha256(staleNotePath)).assertEqual(staleHash);

          await nativeGit2.clone({
            url: FIXTURE_URL,
            targetPath: remoteCheck.path,
            branch: 'xt2',
            username: FIXTURE_USERNAME,
            password: FIXTURE_PASSWORD,
          });
          expect(nativeGit2.getRepositoryState(remoteCheck.path).head).assertEqual(committedOid);
          expect(fileIo.accessSync(registry.trashDirOf(remoteCheck.id) + '/ignored.md')).assertFalse();
          expect(fileIo.readTextSync(registry.trashDirOf(remoteCheck.id) + '/tracked.md'))
            .assertEqual('preserve tracked trash bytes\n');
        } finally {
          removeTree(current.path);
          removeTree(stale.path);
          removeTree(remoteCheck.path);
        }
      });

    it('rejects bad credentials asynchronously and cleans the isolated partial target', 0,
      async (): Promise<void> => {
        const target = newTarget('bad_auth');
        const importingId: string = target.id + '__importing';
        const importingPath: string = registry.vaultDirOf(importingId);
        registry.beginGitImport(target.id, importingId);
        let rejected: boolean = false;
        try {
          await nativeGit2.clone({
            url: FIXTURE_URL,
            targetPath: importingPath,
            branch: 'xt2',
            username: FIXTURE_USERNAME,
            password: 'incorrect-test-password',
          });
        } catch {
          rejected = true;
        } finally {
          registry.cleanupGitImport(target.id, importingId);
        }
        expect(rejected).assertTrue();
        expect(fileIo.accessSync(importingPath)).assertFalse();
        expect(fileIo.accessSync(target.path)).assertFalse();
      });

    it('rejects an unreachable endpoint and cleans the isolated partial target', 0,
      async (): Promise<void> => {
        const target = newTarget('offline');
        const importingId: string = target.id + '__importing';
        const importingPath: string = registry.vaultDirOf(importingId);
        registry.beginGitImport(target.id, importingId);
        let rejected: boolean = false;
        try {
          await nativeGit2.clone({
            url: 'http://127.0.0.1:19440/unreachable.git',
            targetPath: importingPath,
            branch: 'xt2',
          });
        } catch {
          rejected = true;
        } finally {
          registry.cleanupGitImport(target.id, importingId);
        }
        expect(rejected).assertTrue();
        expect(fileIo.accessSync(importingPath)).assertFalse();
        expect(fileIo.accessSync(target.path)).assertFalse();
      });

    it('sends a bearer token in the Authorization header', 0, async (): Promise<void> => {
      const target = newTarget('bearer_auth');
      try {
        await nativeGit2.clone({
          url: FIXTURE_URL,
          targetPath: target.path,
          branch: 'xt2',
          bearerToken: 'fixture-bearer-token',
        });
        const state: Git2RepositoryState = nativeGit2.getRepositoryState(target.path);
        expect(state.branch).assertEqual('xt2');
        expect(state.clean).assertTrue();
      } finally {
        removeTree(target.path);
      }
    });

    it('refuses an existing target without changing its sentinel file', 0, async (): Promise<void> => {
      const target = newTarget('existing_target');
      fileIo.mkdirSync(target.path);
      const sentinelPath: string = registry.absoluteIn(target.id, 'sentinel.txt');
      const sentinel: fileIo.File = fileIo.openSync(sentinelPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(sentinel.fd, 'keep existing bytes');
      } finally {
        fileIo.closeSync(sentinel);
      }
      let rejected: boolean = false;
      try {
        await nativeGit2.clone({ url: FIXTURE_URL, targetPath: target.path });
      } catch {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(fileIo.readTextSync(sentinelPath)).assertEqual('keep existing bytes');
      removeTree(target.path);
    });

    it('clones a public HTTPS fixture with the system CA bundle', 0, async (): Promise<void> => {
      const target = newTarget('https_ca');
      try {
        await nativeGit2.clone({ url: PUBLIC_HTTPS_FIXTURE_URL, targetPath: target.path });
        const state: Git2RepositoryState = nativeGit2.getRepositoryState(target.path);
        expect(state.branch.length > 0).assertTrue();
        expect(state.clean).assertTrue();
      } finally {
        removeTree(target.path);
      }
    });

    beforeAll((): void => {
      const context: common.UIAbilityContext = abilityDelegatorRegistry.getAbilityDelegator()
        .getAppContext() as common.UIAbilityContext;
      registry = VaultRegistry.initialize(context);
    });

    afterAll((): void => {
      for (let i: number = 0; i < testVaultIds.length; i++) {
        removeTree(registry.vaultDirOf(testVaultIds[i]));
      }
      testVaultIds.length = 0;
    });
  });
}
