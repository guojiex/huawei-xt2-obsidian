import { describe, it, expect } from '@ohos/hypium';
import { FullTextSearchResult, SearchIndex } from '../main/ets/model/SearchIndex';

export default function searchIndexTest() {
  describe('current-vault full-text index', () => {
    it('finds Chinese phrases and returns the current note path with matching context', 0, () => {
      const index: SearchIndex = new SearchIndex();
      const documents: Map<string, string> = new Map<string, string>();
      documents.set('甲/每日记录.md', '先记录观察。全文索引应找到这段中文内容，并展示匹配上下文。');
      documents.set('乙/每日记录.md', '另一篇同名笔记没有目标语句。');
      index.addOrReplace('甲/每日记录.md', documents.get('甲/每日记录.md') as string);
      index.addOrReplace('乙/每日记录.md', documents.get('乙/每日记录.md') as string);

      const results: FullTextSearchResult[] = index.search('中文内容', (path: string): string | null => {
        const content: string | undefined = documents.get(path);
        return content === undefined ? null : content;
      });
      expect(results.length).assertEqual(1);
      expect(results[0].path).assertEqual('甲/每日记录.md');
      expect(results[0].excerpt.indexOf('中文内容') >= 0).assertTrue();
    });

    it('updates saved text and retargets moved paths without retaining old matches', 0, () => {
      const index: SearchIndex = new SearchIndex();
      const documents: Map<string, string> = new Map<string, string>();
      const oldPath: string = '草稿/计划.md';
      documents.set(oldPath, '旧内容标记');
      index.addOrReplace(oldPath, '旧内容标记');

      documents.set(oldPath, '新的索引更新标记');
      index.addOrReplace(oldPath, documents.get(oldPath) as string);
      expect(index.search('旧内容', (path: string): string | null => {
        const content: string | undefined = documents.get(path);
        return content === undefined ? null : content;
      }).length).assertEqual(0);
      expect(index.search('索引更新', (path: string): string | null => {
        const content: string | undefined = documents.get(path);
        return content === undefined ? null : content;
      }).length).assertEqual(1);

      documents.set('归档/计划.md', documents.get(oldPath) as string);
      documents.delete(oldPath);
      index.retarget(oldPath, '归档/计划.md', false);
      const moved: FullTextSearchResult[] = index.search('索引更新', (path: string): string | null => {
        const content: string | undefined = documents.get(path);
        return content === undefined ? null : content;
      });
      expect(moved.length).assertEqual(1);
      expect(moved[0].path).assertEqual('归档/计划.md');
    });

    it('removes a deleted directory subtree and ignores stale indexed content', 0, () => {
      const index: SearchIndex = new SearchIndex();
      index.addOrReplace('归档/a.md', '共同关键字');
      index.addOrReplace('归档/子目录/b.md', '共同关键字');
      index.remove('归档', true);
      expect(index.search('共同关键字', (_path: string): string | null => '共同关键字').length).assertEqual(0);

      index.addOrReplace('仍存在.md', '旧标记');
      expect(index.search('旧标记', (_path: string): string | null => '当前内容已变更').length).assertEqual(0);
    });

    it('handles empty and single-character queries', 0, () => {
      const index: SearchIndex = new SearchIndex();
      index.addOrReplace('样例.md', '写下今天的观察');
      expect(index.search('  ', (_path: string): string | null => '写下今天的观察').length).assertEqual(0);
      expect(index.search('观', (_path: string): string | null => '写下今天的观察').length).assertEqual(1);
      expect(index.search('不存在', (_path: string): string | null => '写下今天的观察').length).assertEqual(0);
    });

    it('measures initial indexing and repeated search across 1000 notes', 0, () => {
      const index: SearchIndex = new SearchIndex();
      const documents: Map<string, string> = new Map<string, string>();
      const buildStarted: number = Date.now();
      for (let i = 0; i < 1000; i++) {
        const path: string = '分组' + Math.floor(i / 100).toString() + '/子组' +
          Math.floor((i % 100) / 20).toString() + '/同名笔记' + (i % 20).toString() + '.md';
        const content: string = '第' + i.toString() + '篇中文记录，包含分层目录与同名笔记。' +
          (i % 100 === 0 ? '全文检索性能基准关键词。' : '普通记录内容。');
        documents.set(path, content);
        index.addOrReplace(path, content);
      }
      const buildMillis: number = Date.now() - buildStarted;
      const queryStarted: number = Date.now();
      let results: FullTextSearchResult[] = [];
      for (let i = 0; i < 20; i++) {
        results = index.search('性能基准关键词', (path: string): string | null => {
          const content: string | undefined = documents.get(path);
          return content === undefined ? null : content;
        });
      }
      const repeatedQueryMillis: number = Date.now() - queryStarted;
      console.info('1000-note synthetic index: build=' + buildMillis.toString() + 'ms, 20 queries=' +
        repeatedQueryMillis.toString() + 'ms');
      expect(results.length).assertEqual(10);
      expect(buildMillis < 10000).assertTrue();
      expect(repeatedQueryMillis < 5000).assertTrue();
    });
  });
}
