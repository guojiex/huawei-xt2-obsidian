import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { afterAll, beforeAll, describe, expect, it, ArgumentMatchers, MockKit, when } from '@ohos/hypium';
import { NoteDraftService } from '../main/ets/model/NoteDraftService';
import { NoteService } from '../main/ets/model/NoteService';
import { VaultRegistry } from '../main/ets/model/VaultRegistry';
import { VaultEntry } from '../main/ets/model/Vault';
import { VaultPathResolver } from '../main/ets/model/VaultPathResolver';

let registry: VaultRegistry;
let firstVaultId: string = '';
let secondVaultId: string = '';
let appContext: common.UIAbilityContext;
let contextMock: MockKit;
let testRoot: string = '';
let draftWriterMock: MockKit;
let draftRecords: Map<string, DraftRecordForTest> = new Map<string, DraftRecordForTest>();

interface DraftRecordForTest {
  version: number;
  baseText: string;
  content: string;
}

class DraftTestRegistry {
  private resolver: VaultPathResolver;

  constructor(context: common.UIAbilityContext) {
    this.resolver = new VaultPathResolver(context);
  }

  list(): VaultEntry[] {
    return [
      { id: firstVaultId, type: 'local', createdAt: 1 },
      { id: secondVaultId, type: 'local', createdAt: 2 }
    ];
  }

  absoluteIn(vaultId: string, relativePath: string): string {
    return this.resolver.resolve(vaultId, relativePath);
  }

  draftsRoot(): string {
    return this.resolver.draftsRoot();
  }

  draftsRootRecoveryFile(): string {
    return this.resolver.draftsRootRecoveryFile();
  }

  draftsVaultDirOf(vaultId: string): string {
    return this.resolver.draftsVaultDir(vaultId);
  }

  draftDirectory(vaultId: string, relativeDirectory: string): string {
    return this.resolver.draftDirectory(vaultId, relativeDirectory);
  }

  absoluteDraftIn(vaultId: string, relativePath: string): string {
    return this.resolver.resolveDraft(vaultId, relativePath);
  }
}

function writeTestText(path: string, content: string): void {
  if (fileIo.accessSync(path)) {
    fileIo.unlinkSync(path);
  }
  const file: fileIo.File = fileIo.openSync(path,
    fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
  try {
    if (content.length > 0) {
      fileIo.writeSync(file.fd, content);
    }
  } finally {
    fileIo.closeSync(file);
  }
}

async function writeTestDraft(registryValue: Object, vaultIdValue: string,
  relPathValue: string, contentValue: string): Promise<void> {
  const testRegistry: VaultRegistry = registryValue as VaultRegistry;
  const root: string = testRegistry.draftsRoot();
  if (!fileIo.accessSync(root)) {
    fileIo.mkdirSync(root);
  }
  const vaultRoot: string = testRegistry.draftsVaultDirOf(vaultIdValue);
  if (!fileIo.accessSync(vaultRoot)) {
    fileIo.mkdirSync(vaultRoot);
  }
  const segments: string[] = relPathValue.split('/');
  for (let i = 1; i < segments.length; i++) {
    const parent: string = testRegistry.draftDirectory(vaultIdValue, segments.slice(0, i).join('/'));
    if (!fileIo.accessSync(parent)) {
      fileIo.mkdirSync(parent);
    }
  }
  const path: string = testRegistry.absoluteDraftIn(vaultIdValue, relPathValue);
  draftRecords.set(path, JSON.parse(contentValue) as DraftRecordForTest);
  writeTestText(path, contentValue);
}

function readTestDraft(registryValue: Object, vaultIdValue: string,
  relPathValue: string): DraftRecordForTest | null {
  const testRegistry: VaultRegistry = registryValue as VaultRegistry;
  const path: string = testRegistry.absoluteDraftIn(vaultIdValue, relPathValue);
  const record: DraftRecordForTest | undefined = draftRecords.get(path);
  return record === undefined ? null : record;
}

function removeTestDraft(registryValue: Object, vaultIdValue: string, relPathValue: string): void {
  const testRegistry: VaultRegistry = registryValue as VaultRegistry;
  const path: string = testRegistry.absoluteDraftIn(vaultIdValue, relPathValue);
  draftRecords.delete(path);
  if (fileIo.accessSync(path)) {
    fileIo.unlinkSync(path);
  }
}

function removeTestDraftDirectory(registryValue: Object, vaultIdValue: string,
  relativeDirectoryValue: string): void {
  const testRegistry: VaultRegistry = registryValue as VaultRegistry;
  const dirPath: string = testRegistry.draftDirectory(vaultIdValue, relativeDirectoryValue);
  const prefix: string = dirPath.length > 0 ? dirPath + '/' : '';
  const pathsToDelete: string[] = [];
  draftRecords.forEach((record: DraftRecordForTest, path: string): void => {
    if (path.startsWith(prefix)) {
      pathsToDelete.push(path);
    }
  });
  for (let i = 0; i < pathsToDelete.length; i++) {
    draftRecords.delete(pathsToDelete[i]);
  }
  if (fileIo.accessSync(dirPath)) {
    fileIo.rmdirSync(dirPath);
  }
}

async function copyTestDrafts(registryValue: Object, sourceVaultIdValue: string,
  sourcePathValue: string, targetVaultIdValue: string, targetPathValue: string,
  isDirectoryValue: boolean): Promise<boolean> {
  const testRegistry: VaultRegistry = registryValue as VaultRegistry;
  const sourceFile: string = testRegistry.absoluteDraftIn(sourceVaultIdValue, sourcePathValue);
  const sourcePrefix: string = testRegistry.draftDirectory(sourceVaultIdValue, sourcePathValue) + '/';
  const matchingPaths: string[] = [];
  draftRecords.forEach((record: DraftRecordForTest, path: string): void => {
    if (isDirectoryValue ? path.startsWith(sourcePrefix) : path === sourceFile) {
      matchingPaths.push(path);
    }
  });
  for (let i = 0; i < matchingPaths.length; i++) {
    const sourceRecord: DraftRecordForTest | undefined = draftRecords.get(matchingPaths[i]);
    if (sourceRecord === undefined) {
      continue;
    }
    const suffix: string = isDirectoryValue
      ? matchingPaths[i].substring(sourcePrefix.length).substring(0,
        matchingPaths[i].substring(sourcePrefix.length).length - '.draft'.length)
      : '';
    const targetNotePath: string = isDirectoryValue && suffix.length > 0
      ? targetPathValue + '/' + suffix : targetPathValue;
    await writeTestDraft(registryValue, targetVaultIdValue, targetNotePath,
      JSON.stringify(sourceRecord));
  }
  return matchingPaths.length > 0;
}

export default function noteDraftServiceTest() {
  describe('NoteDraftService', () => {
    beforeAll((): void => {
      appContext = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as common.UIAbilityContext;
      const suffix: string = Date.now().toString();
      firstVaultId = 'codex_draft_test_a_' + suffix;
      secondVaultId = 'codex_draft_test_b_' + suffix;
      testRoot = '/tmp/codex_note_draft_test_' + suffix;
      contextMock = new MockKit();
      contextMock.mockProperty(appContext as Object, 'filesDir', testRoot);
      fileIo.mkdirSync(testRoot);
      const testRegistry: DraftTestRegistry = new DraftTestRegistry(appContext);
      const vaultsRoot: string = new VaultPathResolver(appContext).vaultsRoot();
      if (!fileIo.accessSync(vaultsRoot)) {
        fileIo.mkdirSync(vaultsRoot);
      }
      const firstVaultPath: string = testRegistry.absoluteIn(firstVaultId, '');
      const secondVaultPath: string = testRegistry.absoluteIn(secondVaultId, '');
      if (!fileIo.accessSync(firstVaultPath)) {
        fileIo.mkdirSync(firstVaultPath);
      }
      if (!fileIo.accessSync(secondVaultPath)) {
        fileIo.mkdirSync(secondVaultPath);
      }
      registry = testRegistry as Object as VaultRegistry;
      draftWriterMock = new MockKit();
      // Darwin 本地 Hypium 运行器不提供 readTextSync/listFileSync 与 AtomicFile。
      // 只替代存储边界，保留真实恢复、基线比较和路径决策逻辑。
      const writeAtomicMock: Function = draftWriterMock.mockPrivateFunc(
        NoteDraftService as Object, 'writeAtomic');
      when(writeAtomicMock)(ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any, ArgumentMatchers.any).afterAction(writeTestDraft);
      const readRecordMock: Function = draftWriterMock.mockPrivateFunc(
        NoteDraftService as Object, 'readRecord');
      when(readRecordMock)(ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any).afterAction(readTestDraft);
      const removeDraftMock: Function = draftWriterMock.mockPrivateFunc(
        NoteDraftService as Object, 'removeDraftFile');
      when(removeDraftMock)(ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any).afterAction(removeTestDraft);
      const removeDirectoryMock: Function = draftWriterMock.mockPrivateFunc(
        NoteDraftService as Object, 'removeDraftDirectory');
      when(removeDirectoryMock)(ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any).afterAction(removeTestDraftDirectory);
      const copyDraftMock: Function = draftWriterMock.mockPrivateFunc(
        NoteDraftService as Object, 'copySubtree');
      when(copyDraftMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any,
        ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
        .afterAction(copyTestDrafts);
    });

    afterAll(async (): Promise<void> => {
      await NoteDraftService.discardVault(registry, firstVaultId);
      await NoteDraftService.discardVault(registry, secondVaultId);
      fileIo.rmdirSync(registry.absoluteIn(firstVaultId, ''));
      fileIo.rmdirSync(registry.absoluteIn(secondVaultId, ''));
      fileIo.rmdirSync(registry.draftsRoot());
      fileIo.rmdirSync(new VaultPathResolver(appContext).vaultsRoot());
      fileIo.rmdirSync(testRoot);
      draftRecords.clear();
      draftWriterMock.ignoreMock(NoteDraftService as Object, 'writeAtomic');
      draftWriterMock.ignoreMock(NoteDraftService as Object, 'readRecord');
      draftWriterMock.ignoreMock(NoteDraftService as Object, 'removeDraftFile');
      draftWriterMock.ignoreMock(NoteDraftService as Object, 'removeDraftDirectory');
      draftWriterMock.ignoreMock(NoteDraftService as Object, 'copySubtree');
      contextMock.ignoreMock(appContext as Object, 'filesDir');
    });

    it('persists and recovers the latest Chinese edit from the isolated draft store', 0,
      async (): Promise<void> => {
        const relPath: string = 'draft_cases/rapid.md';
        const baseText: string = '# 初始内容\n';
        const firstEdit: string = '# 连续输入 1\n';
        const finalEdit: string = '# 连续输入完成：你好，曜石笔记\n';
        NoteService.createNote(registry, firstVaultId, relPath);
        writeTestText(registry.absoluteIn(firstVaultId, relPath), baseText);

        await NoteDraftService.persist(registry, firstVaultId, relPath, baseText, firstEdit);
        await NoteDraftService.persist(registry, firstVaultId, relPath, baseText, finalEdit);

        const stored: DraftRecordForTest = draftRecords.get(
          registry.absoluteDraftIn(firstVaultId, relPath)) as DraftRecordForTest;
        expect(stored.baseText).assertEqual(baseText);
        expect(stored.content).assertEqual(finalEdit);

        const recovered = await NoteDraftService.recover(registry, firstVaultId, relPath, baseText);
        expect(recovered.recovered).assertTrue();
        expect(recovered.content).assertEqual(finalEdit);
      });

    it('isolates the same file path across vaults and sibling files', 0,
      async (): Promise<void> => {
        const sharedPath: string = 'same.md';
        const siblingPath: string = 'sibling.md';
        const firstBase: string = '库 A 正式内容';
        const secondBase: string = '库 B 正式内容';
        const siblingBase: string = '同库另一篇';
        NoteService.createNote(registry, firstVaultId, sharedPath);
        NoteService.createNote(registry, firstVaultId, siblingPath);
        NoteService.createNote(registry, secondVaultId, sharedPath);
        writeTestText(registry.absoluteIn(firstVaultId, sharedPath), firstBase);
        writeTestText(registry.absoluteIn(firstVaultId, siblingPath), siblingBase);
        writeTestText(registry.absoluteIn(secondVaultId, sharedPath), secondBase);
        await NoteDraftService.persist(registry, firstVaultId, sharedPath, firstBase, '库 A 草稿');
        await NoteDraftService.persist(registry, firstVaultId, siblingPath, siblingBase, '同库另一篇草稿');
        await NoteDraftService.persist(registry, secondVaultId, sharedPath, secondBase, '库 B 草稿');

        const first = await NoteDraftService.recover(registry, firstVaultId, sharedPath, firstBase);
        const sibling = await NoteDraftService.recover(registry, firstVaultId, siblingPath, siblingBase);
        const second = await NoteDraftService.recover(registry, secondVaultId, sharedPath, secondBase);
        expect(first.content).assertEqual('库 A 草稿');
        expect(sibling.content).assertEqual('同库另一篇草稿');
        expect(second.content).assertEqual('库 B 草稿');
      });

    it('does not restore a draft over newer formal content', 0, async (): Promise<void> => {
      const relPath: string = 'newer.md';
      const baseText: string = '旧正式内容';
      const draftText: string = '旧草稿';
      const newerText: string = '后来更新的正式内容';
      NoteService.createNote(registry, firstVaultId, relPath);
      writeTestText(registry.absoluteIn(firstVaultId, relPath), baseText);
      await NoteDraftService.persist(registry, firstVaultId, relPath, baseText, draftText);

      const result = await NoteDraftService.recover(registry, firstVaultId, relPath, newerText);
      expect(result.recovered).assertFalse();
      expect(result.conflict).assertTrue();
      expect(result.content).assertEqual(newerText);
      expect(fileIo.accessSync(registry.absoluteDraftIn(firstVaultId, relPath))).assertFalse();
    });

    it('writes and recovers an empty edit', 0, async (): Promise<void> => {
      const relPath: string = 'empty.md';
      const baseText: string = '将被清空的内容';
      NoteService.createNote(registry, firstVaultId, relPath);
      writeTestText(registry.absoluteIn(firstVaultId, relPath), baseText);
      await NoteDraftService.persist(registry, firstVaultId, relPath, baseText, '');

      const result = await NoteDraftService.recover(registry, firstVaultId, relPath, baseText);
      expect(result.recovered).assertTrue();
      expect(result.content).assertEqual('');
    });

    it('clears only the draft matching a successfully saved snapshot', 0,
      async (): Promise<void> => {
        const relPath: string = 'saved.md';
        const baseText: string = '保存前';
        const editedText: string = '保存成功后的中文内容';
        NoteService.createNote(registry, firstVaultId, relPath);
        writeTestText(registry.absoluteIn(firstVaultId, relPath), baseText);
        await NoteDraftService.persist(registry, firstVaultId, relPath, baseText, editedText);
        writeTestText(registry.absoluteIn(firstVaultId, relPath), editedText);
        await NoteDraftService.clearIfMatches(registry, firstVaultId, relPath, editedText);

        const result = await NoteDraftService.recover(registry, firstVaultId, relPath, editedText);
        expect(result.recovered).assertFalse();
        expect(result.content).assertEqual(editedText);
        expect(fileIo.accessSync(registry.absoluteDraftIn(firstVaultId, relPath))).assertFalse();
      });

    it('keeps a persisted draft recoverable when the formal AtomicFile save fails', 0,
      async (): Promise<void> => {
        const relPath: string = 'blocked/note.md';
        const baseText: string = '保存失败前的正式内容';
        const editedText: string = '正式保存失败后仍可恢复';
        NoteService.createNote(registry, firstVaultId, relPath);
        writeTestText(registry.absoluteIn(firstVaultId, relPath), baseText);
        await NoteDraftService.persist(registry, firstVaultId, relPath, baseText, editedText);

        const saveMocker: MockKit = new MockKit();
        const runAtomicSaveMock: Function = saveMocker.mockPrivateFunc(
          NoteService as Object, 'runAtomicSave');
        when(runAtomicSaveMock)(ArgumentMatchers.any, ArgumentMatchers.any,
          ArgumentMatchers.any).afterAction((): Promise<void> => {
          return Promise.reject(new Error('单测模拟正式 AtomicFile 写入失败'));
        });
        let saveFailed: boolean = false;
        try {
          await NoteService.saveNote(registry, firstVaultId, relPath, editedText);
        } catch (error) {
          saveFailed = true;
        } finally {
          saveMocker.ignoreMock(NoteService as Object, 'runAtomicSave');
        }
        expect(saveFailed).assertTrue();

        const result = await NoteDraftService.recover(registry, firstVaultId, relPath, baseText);
        expect(result.recovered).assertTrue();
        expect(result.content).assertEqual(editedText);
      });

    it('moves drafts with their directory and discards them on deletion', 0,
      async (): Promise<void> => {
        const sourcePath: string = 'move_source/child.md';
        const baseText: string = '移动前正式内容';
        const draftText: string = '移动中的草稿';
        NoteService.createNote(registry, firstVaultId, sourcePath);
        writeTestText(registry.absoluteIn(firstVaultId, sourcePath), baseText);
        await NoteDraftService.persist(registry, firstVaultId, sourcePath, baseText, draftText);

        const movedDir = await NoteService.movePath(registry, firstVaultId,
          'move_source', 'archive', true);
        const movedPath: string = movedDir.path + '/child.md';
        const moved = await NoteDraftService.recover(registry, firstVaultId, movedPath, baseText);
        expect(moved.recovered).assertTrue();
        expect(moved.content).assertEqual(draftText);
        expect(fileIo.accessSync(registry.absoluteDraftIn(firstVaultId, sourcePath))).assertFalse();

        const deletedPath: string = 'delete.md';
        NoteService.createNote(registry, firstVaultId, deletedPath);
        writeTestText(registry.absoluteIn(firstVaultId, deletedPath), baseText);
        await NoteDraftService.persist(registry, firstVaultId, deletedPath, baseText, draftText);
        await NoteService.deletePath(registry, firstVaultId, deletedPath);
        expect(fileIo.accessSync(registry.absoluteDraftIn(firstVaultId, deletedPath))).assertFalse();
      });
  });
}
