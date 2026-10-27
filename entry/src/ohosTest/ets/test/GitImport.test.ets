import { fileIo } from '@kit.CoreFileKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { afterAll, ArgumentMatchers, beforeAll, describe, expect, it, MockKit, when } from '@ohos/hypium';
import { GitFsBackend } from '../../../main/ets/git/GitFsBackend';
import { VaultRegistry } from '../../../main/ets/model/VaultRegistry';

let registry: VaultRegistry;
const testRoots: string[] = [];
const base64: util.Base64Helper = new util.Base64Helper();
const encoder: util.TextEncoder = new util.TextEncoder();

function makeRootId(label: string): string {
  return registry.uniqueVaultId('codex_git_' + label + '_' + Date.now().toString(), '');
}

function removeTree(path: string): void {
  if (!fileIo.accessSync(path)) {
    return;
  }
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

export default function gitImportTest() {
  describe('GitImport', () => {
    it('preserves text, empty, and arbitrary binary bytes in an isolated import root', 0,
      async (): Promise<void> => {
        const importingId: string = registry.uniqueVaultId(makeRootId('bytes') + '__importing', '');
        const root: string = registry.vaultDirOf(importingId);
        testRoots.push(root);
        const backend: GitFsBackend = new GitFsBackend(root, true);
        backend.ensureRoot();

        const noteBytes: Uint8Array = encoder.encodeInto('# 原始字节\n包含中文文本与换行。\n');
        const imageBytes: Uint8Array = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x00, 0xff, 0x80, 0x01]);
        const emptyBytes: Uint8Array = new Uint8Array(0);
        await backend.write('笔记.md', base64.encodeToStringSync(noteBytes));
        await backend.write('空文件.bin', base64.encodeToStringSync(emptyBytes));
        await backend.write('50_Assets/pixel.png', base64.encodeToStringSync(imageBytes));

        expect(base64.decodeSync(backend.read('笔记.md').dataB64).join(',')).assertEqual(noteBytes.join(','));
        expect(base64.decodeSync(backend.read('空文件.bin').dataB64).length).assertEqual(0);
        expect(base64.decodeSync(backend.read('50_Assets/pixel.png').dataB64).join(',')).assertEqual(imageBytes.join(','));
      });

    it('refuses binary writes outside import mode without changing an existing text file', 0,
      async (): Promise<void> => {
        const existingId: string = makeRootId('existing');
        const root: string = registry.vaultDirOf(existingId);
        testRoots.push(root);
        const backend: GitFsBackend = new GitFsBackend(root);
        backend.ensureRoot();
        const original: Uint8Array = encoder.encodeInto('保留已有文件内容\n');
        await backend.write('existing.md', base64.encodeToStringSync(original));

        const invalidBinary: Uint8Array = new Uint8Array([0x00, 0xff, 0x80, 0x01]);
        let rejected: boolean = false;
        try {
          await backend.write('existing.md', base64.encodeToStringSync(invalidBinary));
        } catch (error) {
          rejected = true;
        }
        expect(rejected).assertTrue();
        expect(base64.decodeSync(backend.read('existing.md').dataB64).join(',')).assertEqual(original.join(','));
      });

    it('removes the new directory and registration state when registry persistence fails', 0,
      async (): Promise<void> => {
        const finalId: string = makeRootId('register_fail');
        const importingId: string = registry.uniqueVaultId(finalId + '__importing', '');
        registry.beginGitImport(finalId, importingId);
        const importingDir: string = registry.vaultDirOf(importingId);
        fileIo.mkdirSync(importingDir);
        const notePath: string = importingDir + '/partial.md';
        const noteFile: fileIo.File = fileIo.openSync(notePath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
        fileIo.writeSync(noteFile.fd, 'partial import');
        fileIo.closeSync(noteFile);
        const finalDir: string = registry.vaultDirOf(finalId);
        fileIo.renameSync(importingDir, finalDir);

        const mocker: MockKit = new MockKit();
        const persistMock: Function = mocker.mockPrivateFunc(registry as Object, 'persist');
        when(persistMock)(ArgumentMatchers.any).afterAction((): void => {
          throw new Error('injected registry persistence failure');
        });
        let failed: boolean = false;
        try {
          registry.registerGit(finalId, 'http://fixture.invalid/repo.git', 'main', '');
        } catch (error) {
          failed = true;
        } finally {
          mocker.ignoreMock(registry as Object, 'persist');
        }

        expect(failed).assertTrue();
        expect(registry.list().some((entry) => entry.id === finalId)).assertFalse();
        registry.cleanupGitImport(finalId, importingId);
        expect(fileIo.accessSync(finalDir)).assertFalse();
        expect(fileIo.accessSync(importingDir)).assertFalse();
      });

    it('recovers an unregistered final directory left by an interrupted import', 0,
      async (): Promise<void> => {
        const finalId: string = makeRootId('restart');
        const importingId: string = registry.uniqueVaultId(finalId + '__importing', '');
        registry.beginGitImport(finalId, importingId);
        const importingDir: string = registry.vaultDirOf(importingId);
        fileIo.mkdirSync(importingDir);
        const finalDir: string = registry.vaultDirOf(finalId);
        fileIo.renameSync(importingDir, finalDir);

        registry.recoverGitImportResidues();
        expect(registry.list().some((entry) => entry.id === finalId)).assertFalse();
        expect(fileIo.accessSync(finalDir)).assertFalse();
      });

    beforeAll((): void => {
      const context: common.UIAbilityContext = abilityDelegatorRegistry.getAbilityDelegator()
        .getAppContext() as common.UIAbilityContext;
      registry = VaultRegistry.initialize(context);
    });

    afterAll((): void => {
      for (let i: number = 0; i < testRoots.length; i++) {
        removeTree(testRoots[i]);
      }
      testRoots.length = 0;
    });
  });
}
