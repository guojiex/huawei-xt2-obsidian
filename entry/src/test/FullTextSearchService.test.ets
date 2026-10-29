import { ArgumentMatchers, afterAll, afterEach, beforeAll, describe, expect, it, MockKit, when } from '@ohos/hypium';
import { FileTree } from '../main/ets/model/FileTree';
import { FullTextSearchResult } from '../main/ets/model/SearchIndex';
import { FullTextSearchService } from '../main/ets/model/FullTextSearchService';
import { VaultRegistry } from '../main/ets/model/VaultRegistry';

class SearchTestRegistry {
  vaultDirOf(vaultId: string): string {
    return 'search-test-root-' + vaultId;
  }

  absoluteIn(vaultId: string, path: string): string {
    return 'search-test-file-' + vaultId + '/' + path;
  }
}

export default function fullTextSearchServiceTest(): void {
  describe('FullTextSearchService current-vault lifecycle', () => {
    let registry: VaultRegistry;
    let mock: MockKit;
    let filesByRoot: Map<string, string[]>;
    let contentsByPath: Map<string, string>;

    beforeAll((): void => {
      registry = new SearchTestRegistry() as Object as VaultRegistry;
      filesByRoot = new Map<string, string[]>();
      contentsByPath = new Map<string, string>();
      mock = new MockKit();

      const listMock: Function = mock.mockPrivateFunc(FileTree as Object, 'allMarkdownFiles');
      when(listMock)(ArgumentMatchers.any).afterAction((vaultDir: string): string[] => {
        const paths: string[] | undefined = filesByRoot.get(vaultDir);
        return paths === undefined ? [] : paths;
      });
      const readMock: Function = mock.mockPrivateFunc(FullTextSearchService as Object, 'readMarkdown');
      when(readMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
        .afterAction((_registry: Object, vaultId: string, path: string): string => {
          const content: string | undefined = contentsByPath.get('search-test-file-' + vaultId + '/' + path);
          if (content === undefined) {
            throw new Error('测试文件不存在');
          }
          return content;
        });
    });

    afterEach((): void => {
      FullTextSearchService.discardVault('a');
      FullTextSearchService.discardVault('b');
    });

    afterAll((): void => {
      mock.ignoreMock(FileTree as Object, 'allMarkdownFiles');
      mock.ignoreMock(FullTextSearchService as Object, 'readMarkdown');
    });

    it('keeps save, rename, delete, vault switching, and failed-build retry aligned with source files', 0,
      async (): Promise<void> => {
        const fileA: string = registry.absoluteIn('a', 'same.md');
        filesByRoot.set(registry.vaultDirOf('a'), ['same.md']);
        contentsByPath.set(fileA, '原始内容');
        let results: FullTextSearchResult[] = await FullTextSearchService.search(
          registry, 'a', '原始内容', (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(1);

        contentsByPath.set(fileA, '保存后的内容');
        FullTextSearchService.noteSaved('a', 'same.md', '保存后的内容');
        results = await FullTextSearchService.search(registry, 'a', '原始内容',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(0);
        results = await FullTextSearchService.search(registry, 'a', '保存后的内容',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(1);

        const renamedPath: string = registry.absoluteIn('a', '改名.md');
        contentsByPath.set(renamedPath, contentsByPath.get(fileA) as string);
        contentsByPath.delete(fileA);
        FullTextSearchService.pathRetargeted('a', 'same.md', '改名.md', false);
        results = await FullTextSearchService.search(registry, 'a', '保存后的内容',
          (_completed: number, _total: number): void => {});
        expect(results[0].path).assertEqual('改名.md');

        FullTextSearchService.noteRemoved('a', '改名.md', false);
        expect((await FullTextSearchService.search(registry, 'a', '保存后的内容',
          (_completed: number, _total: number): void => {})).length).assertEqual(0);

        const fileB: string = registry.absoluteIn('b', 'same.md');
        filesByRoot.set(registry.vaultDirOf('b'), ['same.md']);
        contentsByPath.set(fileB, '另一个库的隔离词');
        results = await FullTextSearchService.search(registry, 'b', '隔离词',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(1);
        expect((await FullTextSearchService.search(registry, 'b', '保存后的内容',
          (_completed: number, _total: number): void => {})).length).assertEqual(0);

        filesByRoot.set(registry.vaultDirOf('a'), ['重建.md']);
        const rebuildPath: string = registry.absoluteIn('a', '重建.md');
        let buildFailed: boolean = false;
        try {
          await FullTextSearchService.search(registry, 'a', '重建标记',
            (_completed: number, _total: number): void => {});
        } catch (error) {
          buildFailed = true;
        }
        expect(buildFailed).assertTrue();

        contentsByPath.set(rebuildPath, '重建标记');
        results = await FullTextSearchService.search(registry, 'a', '重建标记',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(1);
        expect(results[0].path).assertEqual('重建.md');
      });

    it('removes a trashed note from the index and restores it from the source file', 0,
      async (): Promise<void> => {
        const path: string = '恢复/文件.md';
        const absolutePath: string = registry.absoluteIn('a', path);
        filesByRoot.set(registry.vaultDirOf('a'), [path]);
        contentsByPath.set(absolutePath, '回收站恢复标记');

        let results: FullTextSearchResult[] = await FullTextSearchService.search(
          registry, 'a', '恢复标记', (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(1);

        FullTextSearchService.noteRemoved('a', path, false);
        results = await FullTextSearchService.search(registry, 'a', '恢复标记',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(0);

        FullTextSearchService.noteRestored(registry, 'a', path);
        results = await FullTextSearchService.search(registry, 'a', '恢复标记',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(1);
        expect(results[0].path).assertEqual(path);

        FullTextSearchService.noteRemoved('a', path, false);
        results = await FullTextSearchService.search(registry, 'a', '恢复标记',
          (_completed: number, _total: number): void => {});
        expect(results.length).assertEqual(0);
      });

  });
}
