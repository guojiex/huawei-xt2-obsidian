import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { clampContentRatio, clampNavigationWidth, isSingleLandscapeWindow, navigationWidth } from '../main/ets/model/PaneLayout';
import { NoteShareService } from '../main/ets/model/NoteShareService';
import { NoteImageShareService } from '../main/ets/model/NoteImageShareService';
import { NoteImageService } from '../main/ets/model/NoteImageService';
import { ShareArchiveService } from '../main/ets/model/ShareArchiveService';
import { ShareLinkService } from '../main/ets/model/ShareLinkService';
import { VaultEntry } from '../main/ets/model/Vault';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { appThemeForColorMode } from '../main/ets/common/AppTheme';
import { shouldShowSaveFeedback } from '../main/ets/model/SaveFeedbackPolicy';

export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });

    it('single landscape is derived from actual window geometry', 0, () => {
      expect(isSingleLandscapeWindow(780, 380)).assertEqual(true);
      expect(isSingleLandscapeWindow(709, 790)).assertEqual(false);
      expect(isSingleLandscapeWindow(1061, 790)).assertEqual(false);
      expect(isSingleLandscapeWindow(380, 790)).assertEqual(false);
    });

    it('shows save feedback only for a successful, current note write', 0, () => {
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: true,
        saveRevisionCurrent: true,
        noteViewActive: true,
        targetCurrent: true
      })).assertTrue();
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: false,
        feedbackEnabled: true,
        saveRevisionCurrent: true,
        noteViewActive: true,
        targetCurrent: true
      })).assertFalse();
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: false,
        writeSucceeded: true,
        feedbackEnabled: true,
        saveRevisionCurrent: true,
        noteViewActive: true,
        targetCurrent: true
      })).assertFalse();
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: false,
        saveRevisionCurrent: true,
        noteViewActive: true,
        targetCurrent: true
      })).assertFalse();
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: true,
        saveRevisionCurrent: false,
        noteViewActive: true,
        targetCurrent: true
      })).assertFalse();
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: true,
        saveRevisionCurrent: true,
        noteViewActive: false,
        targetCurrent: true
      })).assertFalse();
      expect(shouldShowSaveFeedback({
        contentReadSucceeded: true,
        writeSucceeded: true,
        feedbackEnabled: true,
        saveRevisionCurrent: true,
        noteViewActive: true,
        targetCurrent: false
      })).assertFalse();
    });

    it('shared pane widths respect ratio limits and 240vp pane minimums', 0, () => {
      const landscapeNav: number = navigationWidth(780, -1, 1, 1);
      expect(landscapeNav).assertLarger(259);
      expect(landscapeNav).assertLess(261);
      expect(clampNavigationWidth(1, 1061, 2, 2)).assertEqual(240);
      expect(clampNavigationWidth(2000, 1061, 2, 2)).assertLess(489);
      const splitRatio: number = clampContentRatio(0, 676);
      expect(splitRatio).assertLarger(0.35);
      expect(splitRatio).assertLess(0.36);
      expect(clampContentRatio(0.5, 100)).assertEqual(0.5);
    });

    it('maps system color modes to the shared Web theme', 0, () => {
      expect(appThemeForColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK)).assertEqual('dark');
      expect(appThemeForColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT)).assertEqual('light');
      expect(appThemeForColorMode(undefined)).assertEqual('light');
    });

    it('scans Markdown images without treating code or remote images as missing assets', 0, () => {
      const markdown: string = '`![inline](inline.png)`\n\n```md\n![fenced](fenced.png)\n' +
        '<img src="fenced-html.png">\n```\n\n' +
        '![本地](../assets/%E7%AC%94%E8%AE%B0.svg)\n![远端](https://example.com/a.png)\n' +
        '<img alt="带空格" src="../assets/A%20B.png">\n<IMG SRC = \'../assets/图.svg\'>\n' +
        '<img src="https://example.com/raw.svg">\n![[50_Assets/流程 图.svg|流程图]]\n' +
        '![[10_写作/任务清单]]\n<!-- <img src="comment.png"> -->';
      const refs = NoteShareService.scanMarkdownImages(markdown);
      expect(refs.length).assertEqual(6);
      expect(refs[0].source).assertEqual('../assets/%E7%AC%94%E8%AE%B0.svg');
      expect(refs[1].source).assertEqual('https://example.com/a.png');
      expect(refs[2].source).assertEqual('../assets/A%20B.png');
      expect(refs[3].source).assertEqual('../assets/图.svg');
      expect(refs[4].source).assertEqual('https://example.com/raw.svg');
      expect(refs[5].source).assertEqual('50_Assets/流程 图.svg');
      expect(refs[5].rootRelative).assertTrue();
    });

    it('resolves local images once and rejects paths that escape the vault', 0, () => {
      expect(NoteShareService.resolveImagePath('10_写作/基础排版.md', '../50_Assets/%E7%AC%94%E8%AE%B0.svg'))
        .assertEqual('50_Assets/笔记.svg');
      expect(NoteShareService.resolveImagePath('20_样式/双链与嵌入.md', '50_Assets/笔记流程.svg', true))
        .assertEqual('50_Assets/笔记流程.svg');
      let rejected: boolean = false;
      try {
        NoteShareService.resolveImagePath('基础排版.md', '../50_Assets/图.png');
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      rejected = false;
      try {
        NoteShareService.resolveImagePath('目录/基础排版.md', '/outside/图.png');
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('preserves remote image URLs and excludes internal paths from archives', 0, () => {
      expect(NoteShareService.isRemoteImage('//cdn.example.com/图.png')).assertTrue();
      expect(NoteShareService.isRemoteImage('https://example.com/图.png')).assertTrue();
      expect(NoteShareService.isRemoteImage('assets/图.png')).assertFalse();
      expect(NoteShareService.isExcludedVaultPath('.git/config')).assertTrue();
      expect(NoteShareService.isExcludedVaultPath('.trash/old.md')).assertTrue();
      expect(NoteShareService.isExcludedVaultPath('cache/tmp.zip')).assertTrue();
      expect(NoteShareService.isExcludedVaultPath('credentials.json')).assertTrue();
      expect(NoteShareService.isExcludedVaultPath('笔记/分享说明.md')).assertFalse();
    });

    it('rewrites duplicate local image references while keeping remote URLs intact', 0, () => {
      const markdown: string = '![甲](<../图片/流程 图.svg>)\n![乙](<../图片/流程 图.svg>)\n' +
        '![远端](//cdn.example.com/a.png)\n![[图片/封面 图.svg|封面]]\n![[目录/另一个笔记]]';
      const paths: Map<string, string> = new Map<string, string>();
      paths.set('图片/流程 图.svg', '__share_assets/图片/流程 图.svg');
      paths.set('图片/封面 图.svg', 'assets/封面 图.svg');
      const rewritten: string = NoteShareService.rewriteMarkdownImages(markdown, '笔记/开始.md', paths);
      expect(rewritten).assertEqual('![甲](<../__share_assets/%E5%9B%BE%E7%89%87/%E6%B5%81%E7%A8%8B%20%E5%9B%BE.svg>)\n' +
        '![乙](<../__share_assets/%E5%9B%BE%E7%89%87/%E6%B5%81%E7%A8%8B%20%E5%9B%BE.svg>)\n' +
        '![远端](//cdn.example.com/a.png)\n![[assets/%E5%B0%81%E9%9D%A2%20%E5%9B%BE.svg|封面]]\n![[目录/另一个笔记]]');
    });

    it('avoids archive asset path collisions with content already in the selected scope', 0, () => {
      expect(ShareArchiveService.uniqueExternalRoot(['__share_assets/已有.md'], ['目录']))
        .assertEqual('__share_assets_2');
      expect(ShareArchiveService.uniqueExternalRoot(['普通笔记.md'], ['__share_assets']))
        .assertEqual('__share_assets_2');
    });

    it('splits full-page image captures without truncation and enforces the share limit', 0, () => {
      expect(NoteImageShareService.pageTops(720, 800).join(',')).assertEqual('0');
      expect(NoteImageShareService.pageTops(1600, 800).join(',')).assertEqual('0,800');
      expect(NoteImageShareService.pageTops(1600.5, 800).join(',')).assertEqual('0,800,1600');
      let rejected: boolean = false;
      try {
        NoteImageShareService.pageTops(800 * (NoteImageShareService.MAX_PAGES + 1), 800);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('builds encoded relative Markdown image references and handles Picker cancellation', 0, () => {
      expect(NoteImageService.selectedUri([])).assertEqual('');
      expect(NoteImageService.selectedUri(['picker://selected-image'])).assertEqual('picker://selected-image');
      expect(NoteImageService.markdownReference('写作/今天.md', '写作/attachments/流程 图#1.png'))
        .assertEqual('![图片](<attachments/%E6%B5%81%E7%A8%8B%20%E5%9B%BE%231.png>)');
      let rejected: boolean = false;
      try {
        NoteImageService.markdownReference('写作/今天.md', '其他目录/图片.png');
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('builds GitHub and Gitee page links from registered remotes and encoded paths', 0, () => {
      const github: VaultEntry = {
        id: '项目', vaultKey: 'key-1', type: 'git', createdAt: 1,
        remote: 'https://github.com/example/notes.git', branch: 'feature/编辑'
      };
      const noteLink = ShareLinkService.build(github, 'note', '写作/每日记录.md');
      expect(noteLink.url).assertEqual('https://github.com/example/notes/blob/feature%2F%E7%BC%96%E8%BE%91/' +
        '%E5%86%99%E4%BD%9C/%E6%AF%8F%E6%97%A5%E8%AE%B0%E5%BD%95.md');
      expect(noteLink.accessNotice.indexOf('未推送的本地修改') >= 0).assertTrue();
      const gitee: VaultEntry = {
        id: '项目', vaultKey: 'key-2', type: 'git', createdAt: 1,
        remote: 'https://gitee.com/example/notes', branch: 'main'
      };
      expect(ShareLinkService.build(gitee, 'folder', '写作/2026').url)
        .assertEqual('https://gitee.com/example/notes/tree/main/%E5%86%99%E4%BD%9C/2026');
      expect(ShareLinkService.build(gitee, 'vault', '').url).assertEqual('https://gitee.com/example/notes');
    });

    it('refuses unsupported and credential-bearing Git remotes', 0, () => {
      const unsupported: VaultEntry = {
        id: '自建', vaultKey: 'key-3', type: 'git', createdAt: 1,
        remote: 'https://git.example.com/team/notes.git', branch: 'main'
      };
      let rejected: boolean = false;
      try {
        ShareLinkService.build(unsupported, 'vault', '');
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      const credentialBearing: VaultEntry = {
        id: '凭据', vaultKey: 'key-4', type: 'git', createdAt: 1,
        remote: 'https://user:secret@github.com/example/notes.git', branch: 'main'
      };
      rejected = false;
      try {
        ShareLinkService.build(credentialBearing, 'vault', '');
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
