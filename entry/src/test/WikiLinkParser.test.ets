import { describe, expect, it } from '@ohos/hypium';
import { WikiLinkParser, WikiLinkReference } from '../main/ets/model/WikiLinkParser';

export default function wikiLinkParserTest(): void {
  describe('current-vault wikilink parsing and resolution', () => {
    it('parses aliases while ignoring code, escapes, and embeds', 0, (): void => {
      const markdown: string = '[[项目/会议.md|会议记录]] 与 [[同目录]]\n' +
        '`[[行内代码]]`\n```md\n[[代码块]]\n```\n\\[[转义]]\n![[嵌入]]';
      const links: WikiLinkReference[] = WikiLinkParser.parse(markdown);
      expect(links.length).assertEqual(2);
      expect(links[0].target).assertEqual('项目/会议.md');
      expect(links[0].alias).assertEqual('会议记录');
      expect(links[1].target).assertEqual('同目录');
    });

    it('resolves local and root paths exactly, including both Markdown extensions', 0, (): void => {
      const files: string[] = [
        '项目/来源.md', '项目/每日记录.markdown', '项目/嵌套/中文.md',
        '归档/每日记录.md', 'Upper/Plan.md', 'Upper/plan.md'
      ];
      expect(WikiLinkParser.resolve('每日记录', '项目/来源.md', files).path)
        .assertEqual('项目/每日记录.markdown');
      expect(WikiLinkParser.resolve('归档/每日记录', '项目/来源.md', files).path)
        .assertEqual('归档/每日记录.md');
      expect(WikiLinkParser.resolve('./项目/嵌套/中文.md', '其他/来源.md', files).path)
        .assertEqual('项目/嵌套/中文.md');
      expect(WikiLinkParser.resolve('Upper/Plan', '来源.md', files).path).assertEqual('Upper/Plan.md');
      expect(WikiLinkParser.resolve('Upper/PLAN', '来源.md', files).status).assertEqual('missing');
    });

    it('reports extension ambiguity and rejects traversal, hidden paths, and unsupported separators', 0, (): void => {
      const files: string[] = ['notes/目标.md', 'notes/目标.markdown'];
      expect(WikiLinkParser.resolve('目标', 'notes/来源.md', files).status).assertEqual('ambiguous');
      expect(WikiLinkParser.resolve('../秘密', 'notes/来源.md', files).status).assertEqual('invalid');
      expect(WikiLinkParser.resolve('notes\\目标', '来源.md', files).status).assertEqual('invalid');
      expect(WikiLinkParser.resolve('.trash/秘密.md', '来源.md', files).status).assertEqual('invalid');
      expect(WikiLinkParser.resolve('/外部/目标.md', '来源.md', files).status).assertEqual('invalid');
    });

    it('returns path-distinguishable completions and marks missing or ambiguous targets', 0, (): void => {
      const files: string[] = ['甲/同名.md', '乙/同名.md'];
      const candidates = WikiLinkParser.completionCandidates('同名', files);
      expect(candidates.length).assertEqual(2);
      expect(candidates[0].insertTarget).assertEqual('甲/同名.md');
      expect(candidates[1].insertTarget).assertEqual('乙/同名.md');

      const preview: string = WikiLinkParser.renderForPreview(
        '[[缺失|<新笔记>]]\n[[同名]]', '来源.md', files.concat(['同名.md', '同名.markdown']));
      expect(preview.indexOf('（未创建）') >= 0).assertTrue();
      expect(preview.indexOf('目标不唯一，请补全扩展名') >= 0).assertTrue();
      expect(preview.indexOf('&lt;新笔记&gt;') >= 0).assertTrue();
    });
  });

  describe('plain markdown link resolution against the source note directory', () => {
    it('resolves relative, parent, and vault-root destinations with extensions appended', 0, (): void => {
      const files: string[] = ['00_开始/快速上手.md', '10_写作/基础排版.md',
        '10_写作/样式支持清单.markdown', 'A/来源.md', 'A/B/同目录.md'];
      expect(WikiLinkParser.resolveMarkdownLink('B/同目录.md', 'A/来源.md', files).path)
        .assertEqual('A/B/同目录.md');
      expect(WikiLinkParser.resolveMarkdownLink('../10_写作/基础排版.md', '00_开始/快速上手.md', files).path)
        .assertEqual('10_写作/基础排版.md');
      expect(WikiLinkParser.resolveMarkdownLink('10_写作/样式支持清单', '00_开始/快速上手.md', files).path)
        .assertEqual('10_写作/样式支持清单.markdown');
      expect(WikiLinkParser.resolveMarkdownLink('./A/B/同目录.md', '其他.md', files).path)
        .assertEqual('A/B/同目录.md');
    });

    it('strips fragments, decodes percent-encoding, and rejects schemes and root traversal', 0, (): void => {
      const files: string[] = ['A/笔记.md', 'A/目标.md', 'A/缺失前缀.md'];
      expect(WikiLinkParser.resolveMarkdownLink('目标.md#标题', 'A/笔记.md', files).path)
        .assertEqual('A/目标.md');
      expect(WikiLinkParser.resolveMarkdownLink('%E7%9B%AE%E6%A0%87.md', 'A/笔记.md', files).path)
        .assertEqual('A/目标.md');
      expect(WikiLinkParser.resolveMarkdownLink('https://example.com/a.md', 'A/笔记.md', files).status)
        .assertEqual('invalid');
      expect(WikiLinkParser.resolveMarkdownLink('mailto:a@b.c', 'A/笔记.md', files).status)
        .assertEqual('invalid');
      expect(WikiLinkParser.resolveMarkdownLink('#锚点', 'A/笔记.md', files).status)
        .assertEqual('invalid');
      expect(WikiLinkParser.resolveMarkdownLink('/绝对/目标.md', 'A/笔记.md', files).status)
        .assertEqual('invalid');
      expect(WikiLinkParser.resolveMarkdownLink('../../越出库根.md', 'A/笔记.md', files).status)
        .assertEqual('invalid');
      expect(WikiLinkParser.resolveMarkdownLink('../回到库根.md', 'A/笔记.md', ['回到库根.md']).path)
        .assertEqual('回到库根.md');
      expect(WikiLinkParser.resolveMarkdownLink('缺失.md', 'A/笔记.md', files).status)
        .assertEqual('missing');
    });
  });
}
