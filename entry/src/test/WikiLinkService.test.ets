import { afterEach, beforeAll, describe, expect, it } from '@ohos/hypium';
import { VaultAccess } from '../main/ets/model/VaultAccess';
import { VaultRegistry } from '../main/ets/model/VaultRegistry';
import { WikiLinkService } from '../main/ets/model/WikiLinkService';

class WikiLinkTestAccess {
  private vaultId: string;
  private filesByRoot: Map<string, string[]>;
  private contentsByPath: Map<string, string>;
  private failedRoots: Set<string>;

  constructor(vaultId: string, filesByRoot: Map<string, string[]>, contentsByPath: Map<string, string>,
    failedRoots: Set<string>) {
    this.vaultId = vaultId;
    this.filesByRoot = filesByRoot;
    this.contentsByPath = contentsByPath;
    this.failedRoots = failedRoots;
  }

  allNotes(): string[] {
    const root: string = 'wiki-test-root-' + this.vaultId;
    if (this.failedRoots.has(root)) {
      throw new Error('可控索引扫描失败');
    }
    const files: string[] | undefined = this.filesByRoot.get(root);
    return files === undefined ? [] : files.slice();
  }

  readText(path: string): string {
    const content: string | undefined = this.contentsByPath.get('wiki-test-file-' + this.vaultId + '/' + path);
    if (content === undefined) {
      throw new Error('测试文件不存在');
    }
    return content;
  }
}

class WikiLinkTestRegistry {
  private filesByRoot: Map<string, string[]>;
  private contentsByPath: Map<string, string>;
  private failedRoots: Set<string>;

  constructor(filesByRoot: Map<string, string[]>, contentsByPath: Map<string, string>, failedRoots: Set<string>) {
    this.filesByRoot = filesByRoot;
    this.contentsByPath = contentsByPath;
    this.failedRoots = failedRoots;
  }

  vaultDirOf(vaultId: string): string {
    return 'wiki-test-root-' + vaultId;
  }

  absoluteIn(vaultId: string, path: string): string {
    return 'wiki-test-file-' + vaultId + '/' + path;
  }

  accessFor(vaultId: string): VaultAccess {
    return new WikiLinkTestAccess(vaultId, this.filesByRoot, this.contentsByPath, this.failedRoots) as Object as VaultAccess;
  }
}

export default function wikiLinkServiceTest(): void {
  describe('current-vault backlink index and reference updates', () => {
    let registry: VaultRegistry;
    let filesByRoot: Map<string, string[]>;
    let contentsByPath: Map<string, string>;
    let failedRoots: Set<string>;

    beforeAll((): void => {
      filesByRoot = new Map<string, string[]>();
      contentsByPath = new Map<string, string>();
      failedRoots = new Set<string>();
      registry = new WikiLinkTestRegistry(filesByRoot, contentsByPath, failedRoots) as Object as VaultRegistry;
    });

    afterEach((): void => {
      WikiLinkService.discardVault('a');
      WikiLinkService.discardVault('b');
    });

    it('rebuilds per-vault backlinks, applies saves and path changes, and reports partial rewrites', 0,
      async (): Promise<void> => {
        filesByRoot.set(registry.vaultDirOf('a'), ['source.md', 'target.md']);
        contentsByPath.set(registry.absoluteIn('a', 'source.md'), '[[target]]');
        contentsByPath.set(registry.absoluteIn('a', 'target.md'), '目标');
        let links: string[] = await WikiLinkService.backlinks(registry, 'a', 'target.md');
        expect(links.length).assertEqual(1);
        expect(links[0]).assertEqual('source.md');

        WikiLinkService.noteSaved('a', 'source.md', '没有链接');
        contentsByPath.set(registry.absoluteIn('a', 'source.md'), '没有链接');
        links = await WikiLinkService.backlinks(registry, 'a', 'target.md');
        expect(links.length).assertEqual(0);

        filesByRoot.set(registry.vaultDirOf('a'), ['source.md', 'source2.md', 'target.md']);
        contentsByPath.set(registry.absoluteIn('a', 'source2.md'), '[[target]]');
        WikiLinkService.pathAdded('a');
        links = await WikiLinkService.backlinks(registry, 'a', 'target.md');
        expect(links.length).assertEqual(1);
        expect(links[0]).assertEqual('source2.md');

        filesByRoot.set(registry.vaultDirOf('b'), ['other.md', 'target.md']);
        contentsByPath.set(registry.absoluteIn('b', 'other.md'), '[[target]]');
        contentsByPath.set(registry.absoluteIn('b', 'target.md'), '另一库');
        links = await WikiLinkService.backlinks(registry, 'b', 'target.md');
        expect(links.length).assertEqual(1);
        expect(links[0]).assertEqual('other.md');

        filesByRoot.set(registry.vaultDirOf('a'), ['new.md', 'source.md', 'source2.md']);
        contentsByPath.set(registry.absoluteIn('a', 'new.md'), '目标');
        contentsByPath.set(registry.absoluteIn('a', 'source.md'), '[[old.md|别名]] 与 [普通链接](old.md)');
        contentsByPath.set(registry.absoluteIn('a', 'source2.md'), '[[./old]]');
        const written: Map<string, string> = new Map<string, string>();
        const report = await WikiLinkService.rewriteReferences(registry, 'a', 'old.md', 'new.md', false,
          async (path: string, content: string): Promise<void> => {
            if (path === 'source2.md') {
              throw new Error('可控写入失败');
            }
            written.set(path, content);
          });
        expect(report.failedPaths.length).assertEqual(1);
        expect(report.failedPaths[0]).assertEqual('source2.md');
        expect(report.updatedPaths.length).assertEqual(1);
        expect(written.get('source.md')).assertEqual('[[./new.md|别名]] 与 [普通链接](old.md)');
        expect(report.scanFailed).assertFalse();

        filesByRoot.set(registry.vaultDirOf('a'), ['新目录/目标.md', '新目录/来源.md', '外部.md']);
        contentsByPath.set(registry.absoluteIn('a', '新目录/来源.md'), '[[目标]]');
        contentsByPath.set(registry.absoluteIn('a', '外部.md'), '[[旧目录/目标]]');
        const directoryWrites: Map<string, string> = new Map<string, string>();
        const directoryReport = await WikiLinkService.rewriteReferences(registry, 'a', '旧目录', '新目录', true,
          async (path: string, content: string): Promise<void> => {
            directoryWrites.set(path, content);
          });
        expect(directoryReport.updatedPaths.length).assertEqual(1);
        expect(directoryReport.updatedPaths[0]).assertEqual('外部.md');
        expect(directoryWrites.get('外部.md')).assertEqual('[[新目录/目标.md]]');
        expect(directoryWrites.has('新目录/来源.md')).assertFalse();

        failedRoots.add(registry.vaultDirOf('a'));
        const scanFailure = await WikiLinkService.rewriteReferences(registry, 'a', '旧目录', '新目录', true,
          async (_path: string, _content: string): Promise<void> => {});
        expect(scanFailure.scanFailed).assertTrue();
        expect(scanFailure.failedPaths.length).assertEqual(0);
      });
  });
}
