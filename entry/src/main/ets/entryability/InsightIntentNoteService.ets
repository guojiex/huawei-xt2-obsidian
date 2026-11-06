import { AgentOperationStorage, AgentOperationStatus, AgentStoredOperation } from '../model/AgentOperationStorage';
import { AgentRunConfig } from '../model/AgentModels';
import { compareVaultNames } from '../model/VaultAccess';
import { FileTree } from '../model/FileTree';
import { FullTextSearchService } from '../model/FullTextSearchService';
import { NoteService } from '../model/NoteService';
import { VaultRegistry } from '../model/VaultRegistry';
import { WikiLinkParser, WikiLinkReference, WikiLinkResolution } from '../model/WikiLinkParser';
import { WikiLinkService } from '../model/WikiLinkService';
import { WorkspaceEditGuard } from '../model/WorkspaceEditGuard';

interface NoteMatch {
  name: string;
  path: string;
}

/** v1.16 只读搜索的一条命中（16.1）。 */
interface SearchHit {
  path: string;
  title: string;
  line: number;
  snippet: string;
  matchIn: string;
}

/** v1.16 目录浏览的一个条目（16.1）。 */
interface TreeEntry {
  path: string;
  name: string;
  type: string;
  depth: number;
  childCount: number;
  mtime: string;
}

/** v1.16 大纲模式的一条标题（16.1）。 */
interface OutlineItem {
  level: number;
  title: string;
  line: number;
  offset: number;
}

/** v1.16 分段读取的切分结果（UTF-16 码元偏移，与 ArkTS 字符串索引一致）。 */
interface ChunkPlan {
  start: number;
  end: number;
  hasMore: boolean;
}

interface PageSlice {
  items: Object[];
  nextIndex: number;
  skippedCount: number;
}

/** v1.16 出链条目（16.1）。 */
interface OutLink {
  target: string;
  resolvedPath: string;
  status: string;
  alias: string;
}

/** v1.16 反链条目（16.1）。 */
interface InLink {
  path: string;
  title: string;
  context: string;
}

/**
 * 只读工具的默认值集合。
 * 输出预算是本地安全上限，不代表小艺平台的实测限制。
 */
class XiaoyiToolLimits {
  static readonly searchDefaultLimit: number = 8;
  static readonly searchMaxLimit: number = 20;
  static readonly snippetMaxChars: number = 160;
  static readonly listTreeDefaultLimit: number = 50;
  static readonly listTreeMaxLimit: number = 100;
  static readonly listTreeMaxDepth: number = 3;
  static readonly readChunkDefaultChars: number = 4000;
  static readonly readChunkMaxChars: number = 8000;
  static readonly outlineDefaultLimit: number = 100;
  static readonly outlineMaxLimit: number = 100;
  static readonly linksMaxItems: number = 30;
  static readonly outputBudgetChars: number = 6000;
}

/** 小艺后台端插件的本地笔记工具。vaultId 可省略，省略时定位用户当前选择的知识库。 */
export class InsightIntentNoteService {
  private static readonly CONVERSATION_ID: string = 'xiaoyi';
  private static readonly busyVaults: Set<string> = new Set<string>();
  private static serial: number = 0;
  private registry: VaultRegistry;
  private storage: AgentOperationStorage;

  constructor(registry: VaultRegistry) {
    this.registry = registry;
    this.storage = new AgentOperationStorage(registry);
  }

  async execute(name: string, params: Record<string, Object>): Promise<Record<string, Object>> {
    if (name === 'QueryNotes') {
      return this.queryNotes(params);
    }
    if (name === 'ReadNote') {
      return this.readNote(params);
    }
    if (name === 'SearchNotes') {
      return await this.searchNotes(params);
    }
    if (name === 'ListTree') {
      return this.listTree(params);
    }
    if (name === 'GetLinks') {
      return await this.getLinks(params);
    }
    if (name === 'CreateNote') {
      return await this.createNote(params);
    }
    if (name === 'AppendNote') {
      return await this.appendNote(params);
    }
    if (name === 'EditNote') {
      return await this.editNote(params);
    }
    if (name === 'UndoLastEdit') {
      return await this.undoLastEdit(params);
    }
    throw new Error('不支持的笔记端插件工具。');
  }

  private queryNotes(params: Record<string, Object>): Record<string, Object> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const queryValue: Object = params['query'];
    const query: string = typeof queryValue === 'string' ? queryValue.trim().toLocaleLowerCase() : '';
    this.requireVault(vaultId);
    const paths: string[] = FileTree.allNotesOf(this.registry.accessFor(vaultId));
    let matches: NoteMatch[] = [];
    for (let i = 0; i < paths.length; i++) {
      const path: string = paths[i];
      if (query.length > 0 && path.toLocaleLowerCase().indexOf(query) < 0) {
        continue;
      }
      const slash: number = path.lastIndexOf('/');
      matches.push({ name: slash >= 0 ? path.substring(slash + 1) : path, path });
    }
    const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    result['matchesJson'] = JSON.stringify(matches);
    result['total'] = matches.length.toString();
    result['truncated'] = 'false';
    result['message'] = '在知识库「' + vaultId + '」找到 ' + matches.length.toString() + ' 篇候选笔记。';
    if (InsightIntentNoteService.outputChars(result) > XiaoyiToolLimits.outputBudgetChars) {
      const fullJson: string = result['matchesJson'] as string;
      const fixedChars: number = InsightIntentNoteService.outputChars(result) - fullJson.length;
      const keep: number = InsightIntentNoteService.fitJsonArrayCount(matches as Object[],
        XiaoyiToolLimits.outputBudgetChars - fixedChars - 64);
      matches = matches.slice(0, keep);
      result['matchesJson'] = JSON.stringify(matches);
      result['truncated'] = 'true';
      result['message'] = '在知识库「' + vaultId + '」找到 ' + result['total'] +
        ' 篇候选笔记，结果已按输出预算截断。';
    }
    while (InsightIntentNoteService.outputChars(result) > XiaoyiToolLimits.outputBudgetChars &&
      matches.length > 0) {
      matches.pop();
      result['matchesJson'] = JSON.stringify(matches);
      result['truncated'] = 'true';
      result['message'] = '在知识库「' + vaultId + '」找到 ' + result['total'] +
        ' 篇候选笔记，结果已按输出预算截断。';
    }
    InsightIntentNoteService.ensureOutputBudget(result);
    return result;
  }

  private readNote(params: Record<string, Object>): Record<string, Object> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const path: string = this.requiredString(params, 'path');
    this.requireVault(vaultId);
    this.requireExistingNote(vaultId, path);
    if (WorkspaceEditGuard.isUnsaved(vaultId, path)) {
      throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，请先保存后再读取。');
    }
    const content: string | null = NoteService.tryReadNote(this.registry, vaultId, path);
    if (content === null) {
      throw new Error('READ_FAILED：笔记不存在或读取失败。');
    }
    const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    result['contentHash'] = AgentOperationStorage.hashText(content);
    result['path'] = path;
    result['totalChars'] = content.length.toString();
    const mode: string = this.optionalString(params, 'mode', 'text');
    if (mode === 'outline') {
      const allItems: OutlineItem[] = InsightIntentNoteService.buildOutline(content);
      const cursor: number = InsightIntentNoteService.parseCursor(params['cursor']);
      const limit: number = InsightIntentNoteService.parseLimit(params['limit'],
        XiaoyiToolLimits.outlineDefaultLimit, XiaoyiToolLimits.outlineMaxLimit, 'limit');
      const estimatedEnd: number = Math.min(cursor + limit, allItems.length);
      result['mode'] = 'outline';
      result['content'] = '';
      result['offset'] = '0';
      result['returnedChars'] = '0';
      result['hasMore'] = 'false';
      result['truncated'] = 'false';
      result['outlineJson'] = '[]';
      result['total'] = allItems.length.toString();
      result['nextCursor'] = InsightIntentNoteService.encodeCursor(estimatedEnd);
      result['skippedCount'] = '0';
      result['nextOffset'] = content.length.toString();
      result['message'] = '大纲共 ' + allItems.length.toString() + ' 条标题；本页跳过 0 条。';
      const availableJsonChars: number = XiaoyiToolLimits.outputBudgetChars -
        InsightIntentNoteService.outputChars(result) + 2;
      const page: PageSlice = InsightIntentNoteService.fitPage(allItems as Object[], cursor, limit,
        availableJsonChars, availableJsonChars);
      let items: OutlineItem[] = page.items as OutlineItem[];
      let end: number = page.nextIndex;
      result['outlineJson'] = JSON.stringify(items);
      result['skippedCount'] = page.skippedCount.toString();
      result['nextCursor'] = end < allItems.length
        ? InsightIntentNoteService.encodeCursor(end) : '';
      result['nextOffset'] = end < allItems.length
        ? allItems[end].offset.toString() : content.length.toString();
      result['truncated'] = end < allItems.length || page.skippedCount > 0 ? 'true' : 'false';
      result['message'] = '大纲共 ' + allItems.length.toString() + ' 条标题；本页跳过 ' +
        page.skippedCount.toString() + ' 条。';
      while (InsightIntentNoteService.outputChars(result) > XiaoyiToolLimits.outputBudgetChars &&
        items.length > 0) {
        items = items.slice(0, items.length - 1);
        end--;
        result['outlineJson'] = JSON.stringify(items);
        result['nextCursor'] = end < allItems.length
          ? InsightIntentNoteService.encodeCursor(end) : '';
        result['nextOffset'] = end < allItems.length
          ? allItems[end].offset.toString() : content.length.toString();
        result['truncated'] = end < allItems.length || page.skippedCount > 0 ? 'true' : 'false';
        result['message'] = '大纲共 ' + allItems.length.toString() + ' 条标题；本页跳过 ' +
          page.skippedCount.toString() + ' 条。';
      }
      InsightIntentNoteService.ensureOutputBudget(result);
      return result;
    }
    if (mode !== 'text') {
      throw new Error('INVALID_PARAMETER：mode 只支持 text 或 outline。');
    }
    // Keep the legacy whole-note response when it fits; oversized notes use the same offset contract.
    const segmented: boolean = params['offset'] !== undefined || params['length'] !== undefined;
    const offset: number = segmented ? InsightIntentNoteService.parseOffset(params['offset']) : 0;
    const length: number = segmented ? InsightIntentNoteService.parseLimit(params['length'],
      XiaoyiToolLimits.readChunkDefaultChars, XiaoyiToolLimits.readChunkMaxChars, 'length') : content.length;
    const requestedPlan: ChunkPlan = InsightIntentNoteService.planChunk(content, offset, length);
    result['mode'] = 'text';
    result['content'] = '';
    result['offset'] = requestedPlan.start.toString();
    result['returnedChars'] = (requestedPlan.end - requestedPlan.start).toString();
    result['hasMore'] = requestedPlan.hasMore ? 'true' : 'false';
    result['nextOffset'] = requestedPlan.end.toString();
    result['truncated'] = 'false';
    result['message'] = '已读取笔记内容。';
    const fixedChars: number = InsightIntentNoteService.outputChars(result);
    const plan: ChunkPlan = InsightIntentNoteService.fitChunkToOutputBudget(content, offset, length,
      fixedChars + 64);
    if (plan.end < requestedPlan.end) {
      result['offset'] = plan.start.toString();
      result['returnedChars'] = (plan.end - plan.start).toString();
      result['hasMore'] = plan.hasMore ? 'true' : 'false';
      result['nextOffset'] = plan.end.toString();
      result['truncated'] = 'true';
    }
    result['content'] = content.substring(plan.start, plan.end);
    InsightIntentNoteService.ensureOutputBudget(result);
    return result;
  }

  /**
   * v1.16 只读搜索（16.1）：名称 / 全文 / 两者，带分页与截断标记。
   * 全文候选复用 FullTextSearchService（v1.1 语义），不自建索引；索引不可用时报错而不编造结果。
   */
  private async searchNotes(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const query: string = this.requiredString(params, 'query');
    const scope: string = this.optionalString(params, 'scope', 'both');
    if (scope !== 'name' && scope !== 'content' && scope !== 'both') {
      throw new Error('INVALID_PARAMETER：scope 只支持 name、content 或 both。');
    }
    const folder: string = this.optionalString(params, 'folder', '');
    const limit: number = InsightIntentNoteService.parseLimit(params['limit'],
      XiaoyiToolLimits.searchDefaultLimit, XiaoyiToolLimits.searchMaxLimit, 'limit');
    const cursor: number = InsightIntentNoteService.parseCursor(params['cursor']);
    this.requireVault(vaultId);
    const access = this.registry.accessFor(vaultId);
    if (folder.length > 0 && FileTree.allDirsOf(access).indexOf(folder) < 0) {
      throw new Error('OUT_OF_SCOPE：folder 不属于指定知识库或不存在。');
    }
    const scoped: string[] = InsightIntentNoteService.inFolder(FileTree.allNotesOf(access), folder);
    const lowered: string = query.trim().toLocaleLowerCase();
    const nameHits: string[] = [];
    for (let i = 0; i < scoped.length; i++) {
      const path: string = scoped[i];
      const name: string = InsightIntentNoteService.lastSegment(path);
      if (scope !== 'content' && name.toLocaleLowerCase().indexOf(lowered) >= 0) {
        nameHits.push(path);
      }
    }
    const contentHits: string[] = [];
    if (scope !== 'name') {
      let matched: string[] = [];
      try {
        const results = await FullTextSearchService.search(this.registry, vaultId, query, (): void => {
        });
        for (let i = 0; i < results.length; i++) {
          matched.push(results[i].path);
        }
      } catch (error) {
        throw new Error('INDEX_UNAVAILABLE：全文索引暂不可用，请改用 scope=name 或稍后重试。');
      }
      for (let i = 0; i < matched.length; i++) {
        const path: string = matched[i];
        if (nameHits.indexOf(path) < 0 && scoped.indexOf(path) >= 0) {
          contentHits.push(path);
        }
      }
    }
    nameHits.sort((left: string, right: string): number => compareVaultNames(left, right));
    contentHits.sort((left: string, right: string): number => compareVaultNames(left, right));
    const ordered: string[] = nameHits.concat(contentHits);
    const page: string[] = ordered.slice(cursor, cursor + limit);
    const hits: SearchHit[] = [];
    for (let i = 0; i < page.length; i++) {
      const path: string = page[i];
      const matchIn: string = nameHits.indexOf(path) >= 0 ? 'name' : 'content';
      let line: number = 1;
      let snippet: string = '';
      if (matchIn === 'content') {
        const content: string | null = NoteService.tryReadNote(this.registry, vaultId, path);
        if (content !== null) {
          const matchAt: number = content.toLocaleLowerCase().indexOf(lowered);
          line = InsightIntentNoteService.lineOfOffset(content, matchAt < 0 ? 0 : matchAt);
          snippet = InsightIntentNoteService.buildSnippet(content, matchAt, lowered.length);
        }
      }
      hits.push({ path: path, title: InsightIntentNoteService.lastSegment(path), line: line,
        snippet: snippet, matchIn: matchIn });
    }
    const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    let outputHits: SearchHit[] = hits;
    let clipped: boolean = false;
    result['total'] = ordered.length.toString();
    result['hitsJson'] = JSON.stringify(outputHits);
    let end: number = cursor + outputHits.length;
    result['nextCursor'] = end < ordered.length ? InsightIntentNoteService.encodeCursor(end) : '';
    result['truncated'] = end < ordered.length ? 'true' : 'false';
    result['message'] = '在知识库「' + vaultId + '」找到 ' + ordered.length.toString() +
      ' 篇候选笔记，本次返回 ' + outputHits.length.toString() + ' 篇。';
    while (InsightIntentNoteService.outputChars(result) > XiaoyiToolLimits.outputBudgetChars) {
      let clearedSnippet: boolean = false;
      for (let i = outputHits.length - 1; i >= 0; i--) {
        if (outputHits[i].snippet.length > 0) {
          outputHits[i].snippet = '';
          clearedSnippet = true;
          clipped = true;
          break;
        }
      }
      if (!clearedSnippet && outputHits.length > 0) {
        outputHits = outputHits.slice(0, outputHits.length - 1);
        clipped = true;
      } else if (!clearedSnippet) {
        break;
      }
      end = cursor + outputHits.length;
      result['hitsJson'] = JSON.stringify(outputHits);
      result['nextCursor'] = end < ordered.length ? InsightIntentNoteService.encodeCursor(end) : '';
      result['truncated'] = end < ordered.length || clipped ? 'true' : 'false';
      result['message'] = '在知识库「' + vaultId + '」找到 ' + ordered.length.toString() +
        ' 篇候选笔记，本次返回 ' + outputHits.length.toString() +
        (clipped ? ' 篇；结果已按输出预算裁剪。' : ' 篇。');
    }
    InsightIntentNoteService.ensureOutputBudget(result);
    return result;
  }

  /** v1.16 目录浏览（16.1）：目录先于笔记，各自字典序，深度与条数受限。 */
  private listTree(params: Record<string, Object>): Record<string, Object> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const root: string = this.optionalString(params, 'path', '');
    const depth: number = InsightIntentNoteService.parseLimit(params['depth'], 1,
      XiaoyiToolLimits.listTreeMaxDepth, 'depth');
    const limit: number = InsightIntentNoteService.parseLimit(params['limit'],
      XiaoyiToolLimits.listTreeDefaultLimit, XiaoyiToolLimits.listTreeMaxLimit, 'limit');
    const cursor: number = InsightIntentNoteService.parseCursor(params['cursor']);
    this.requireVault(vaultId);
    const access = this.registry.accessFor(vaultId);
    const dirs: string[] = FileTree.allDirsOf(access);
    const notes: string[] = FileTree.allNotesOf(access);
    if (root.length > 0 && dirs.indexOf(root) < 0) {
      throw new Error('OUT_OF_SCOPE：起始目录不属于指定知识库或不存在。');
    }
    const entries: TreeEntry[] = InsightIntentNoteService.collectTreeEntries(dirs, notes, root, depth);
    for (let i = 0; i < entries.length; i++) {
      const stat = access.stat(entries[i].path);
      entries[i].mtime = stat === null ? '' : InsightIntentNoteService.isoDate(stat.mtimeSec);
    }
    let page: TreeEntry[] = entries.slice(cursor, cursor + limit);
    let end: number = cursor + page.length;
    const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    result['entriesJson'] = JSON.stringify(page);
    result['total'] = entries.length.toString();
    result['nextCursor'] = end < entries.length ? InsightIntentNoteService.encodeCursor(end) : '';
    result['truncated'] = end < entries.length ? 'true' : 'false';
    result['message'] = '知识库「' + vaultId + '」该层共 ' + entries.length.toString() +
      ' 个条目，本次返回 ' + page.length.toString() + ' 个。';
    let clipped: boolean = false;
    while (InsightIntentNoteService.outputChars(result) > XiaoyiToolLimits.outputBudgetChars &&
      page.length > 0) {
      page = page.slice(0, page.length - 1);
      end = cursor + page.length;
      clipped = true;
      result['entriesJson'] = JSON.stringify(page);
      result['nextCursor'] = end < entries.length ? InsightIntentNoteService.encodeCursor(end) : '';
      result['truncated'] = end < entries.length || clipped ? 'true' : 'false';
      result['message'] = '知识库「' + vaultId + '」该层共 ' + entries.length.toString() +
        ' 个条目，本次按输出预算返回 ' + page.length.toString() + ' 个。';
    }
    InsightIntentNoteService.ensureOutputBudget(result);
    return result;
  }

  /** v1.16 链接关系（16.1）：出链用 v1.2 解析语义，反链复用 WikiLinkService 的图。 */
  private async getLinks(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const path: string = this.requiredString(params, 'path');
    const direction: string = this.optionalString(params, 'direction', 'both');
    if (direction !== 'out' && direction !== 'in' && direction !== 'both') {
      throw new Error('INVALID_PARAMETER：direction 只支持 out、in 或 both。');
    }
    const limit: number = InsightIntentNoteService.parseLimit(params['limit'],
      XiaoyiToolLimits.linksMaxItems, XiaoyiToolLimits.linksMaxItems, 'limit');
    const requestedOutCursor: number = direction === 'in' ? 0 :
      InsightIntentNoteService.parseCursor(params['outCursor']);
    const requestedInCursor: number = direction === 'out' ? 0 :
      InsightIntentNoteService.parseCursor(params['inCursor']);
    this.requireVault(vaultId);
    this.requireExistingNote(vaultId, path);
    if (WorkspaceEditGuard.isUnsaved(vaultId, path)) {
      throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，请先保存后再读取链接。');
    }
    const content: string | null = NoteService.tryReadNote(this.registry, vaultId, path);
    if (content === null) {
      throw new Error('READ_FAILED：笔记不存在或读取失败。');
    }
    const files: string[] = WikiLinkService.files(this.registry, vaultId);
    const uniqueReferences: WikiLinkReference[] = [];
    if (direction !== 'in') {
      const references: WikiLinkReference[] = WikiLinkParser.parse(content);
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < references.length; i++) {
        const reference: WikiLinkReference = references[i];
        if (seen.has(reference.target)) {
          continue;
        }
        seen.add(reference.target);
        uniqueReferences.push(reference);
      }
    }
    let sources: string[] = [];
    if (direction !== 'out') {
      sources = await WikiLinkService.backlinks(this.registry, vaultId, path);
    }
    const outTotal: number = uniqueReferences.length;
    const inTotal: number = sources.length;
    const outCursor: number = Math.min(requestedOutCursor, outTotal);
    const inCursor: number = Math.min(requestedInCursor, inTotal);
    const outCandidates: OutLink[] = [];
    for (let i = outCursor; i < Math.min(outCursor + limit, uniqueReferences.length); i++) {
      const reference: WikiLinkReference = uniqueReferences[i];
      const resolution: WikiLinkResolution = WikiLinkService.resolve(reference.target, path, files);
      outCandidates.push({ target: reference.target, resolvedPath: resolution.path,
        status: resolution.status, alias: reference.alias });
    }
    const inCandidates: InLink[] = [];
    for (let i = inCursor; i < Math.min(inCursor + limit, sources.length); i++) {
      const sourcePath: string = sources[i];
      const source: string | null = NoteService.tryReadNote(this.registry, vaultId, sourcePath);
      inCandidates.push({ path: sourcePath, title: InsightIntentNoteService.lastSegment(sourcePath),
        context: source === null ? '' :
          InsightIntentNoteService.linkContext(source, sourcePath, path, files) });
    }
    const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    result['outJson'] = '[]';
    result['inJson'] = '[]';
    result['outTotal'] = outTotal.toString();
    result['inTotal'] = inTotal.toString();
    const estimatedOutEnd: number = Math.min(outCursor + limit, outTotal);
    const estimatedInEnd: number = Math.min(inCursor + limit, inTotal);
    result['outNextCursor'] = direction === 'in' ? '' :
      InsightIntentNoteService.encodeCursor(estimatedOutEnd);
    result['inNextCursor'] = direction === 'out' ? '' :
      InsightIntentNoteService.encodeCursor(estimatedInEnd);
    result['outSkipped'] = '0';
    result['inSkipped'] = '0';
    result['truncated'] = (estimatedOutEnd < outTotal || estimatedInEnd < inTotal) ? 'true' : 'false';
    result['message'] = '已读取双链关系：出链 ' + outTotal.toString() + ' 条、反链 ' +
      inTotal.toString() + ' 条。';
    const arrayChars: number = XiaoyiToolLimits.outputBudgetChars -
      InsightIntentNoteService.outputChars(result) + 4;
    const pageArrayChars: number = arrayChars - 2;
    const outPage: PageSlice = direction === 'in'
      ? { items: [], nextIndex: 0, skippedCount: 0 }
      : InsightIntentNoteService.fitPage(outCandidates as Object[], 0, limit, pageArrayChars, pageArrayChars);
    const outgoing: OutLink[] = outPage.items as OutLink[];
    const outEnd: number = outCursor + outPage.nextIndex;
    const outJson: string = JSON.stringify(outgoing);
    const remainingInChars: number = arrayChars - outJson.length;
    const inPage: PageSlice = direction === 'out'
      ? { items: [], nextIndex: 0, skippedCount: 0 }
      : InsightIntentNoteService.fitPage(inCandidates as Object[], 0, limit, remainingInChars, pageArrayChars);
    const incoming: InLink[] = inPage.items as InLink[];
    const inEnd: number = inCursor + inPage.nextIndex;
    result['outJson'] = outJson;
    result['inJson'] = JSON.stringify(incoming);
    result['outNextCursor'] = outEnd < outTotal ? InsightIntentNoteService.encodeCursor(outEnd) : '';
    result['inNextCursor'] = inEnd < inTotal ? InsightIntentNoteService.encodeCursor(inEnd) : '';
    result['outSkipped'] = outPage.skippedCount.toString();
    result['inSkipped'] = inPage.skippedCount.toString();
    result['truncated'] = (outEnd < outTotal || inEnd < inTotal ||
      outPage.skippedCount > 0 || inPage.skippedCount > 0) ? 'true' : 'false';
    InsightIntentNoteService.ensureOutputBudget(result);
    return result;
  }

  private async createNote(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const requestedPath: string = this.requiredString(params, 'path');
    const content: string = this.requiredString(params, 'text', true);
    this.requireVault(vaultId);
    const normalizedPath: string = this.requireSafeNotePath(vaultId, requestedPath);
    this.requireAgentWritablePath(vaultId, normalizedPath);
    this.requireAllowedParent(vaultId, normalizedPath);
    this.enterVault(vaultId);
    try {
      const path: string = NoteService.previewCreatePath(this.registry, vaultId, normalizedPath);
      this.requireAgentWritablePath(vaultId, path);
      this.requireAllowedParent(vaultId, path);
      const record: AgentStoredOperation = await this.beginOperation(
        vaultId, 'CreateNote', path, '', content, true);
      try {
        await NoteService.createNoteWithContent(this.registry, vaultId, path, content);
      } catch (error) {
        await this.finishFailedOperation(vaultId, record);
        throw error as Error;
      }
      await this.finishAppliedOperation(vaultId, record);
      const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
      result['path'] = path;
      result['contentHash'] = record.resultHash;
      result['operationId'] = record.operationId;
      result['message'] = '已在知识库「' + vaultId + '」创建笔记「' + path + '」。';
      return result;
    } finally {
      InsightIntentNoteService.busyVaults.delete(vaultId);
    }
  }

  private async appendNote(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const path: string = this.requiredString(params, 'path');
    const baseHash: string = this.requiredString(params, 'baseHash');
    const addition: string = this.requiredString(params, 'text');
    this.requireVault(vaultId);
    this.requireExistingNote(vaultId, path);
    this.requireAgentWritablePath(vaultId, path);
    if (WorkspaceEditGuard.isUnsaved(vaultId, path)) {
      throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，未追加。');
    }
    this.enterVault(vaultId);
    try {
      const before: string = this.readExpectedVersion(vaultId, path, baseHash);
      const after: string = InsightIntentNoteService.appendText(before, addition);
      return await this.applyExistingMutation(vaultId, 'AppendNote', path, before, after);
    } finally {
      InsightIntentNoteService.busyVaults.delete(vaultId);
    }
  }

  private async editNote(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const path: string = this.requiredString(params, 'path');
    const baseHash: string = this.requiredString(params, 'baseHash');
    const anchor: string = this.requiredString(params, 'anchor');
    const replacement: string = this.requiredString(params, 'text', true);
    this.requireVault(vaultId);
    this.requireExistingNote(vaultId, path);
    this.requireAgentWritablePath(vaultId, path);
    if (WorkspaceEditGuard.isUnsaved(vaultId, path)) {
      throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，未修改。');
    }
    this.enterVault(vaultId);
    try {
      const before: string = this.readExpectedVersion(vaultId, path, baseHash);
      const after: string = InsightIntentNoteService.replaceUniqueAnchor(before, anchor, replacement);
      return await this.applyExistingMutation(vaultId, 'EditNote', path, before, after);
    } finally {
      InsightIntentNoteService.busyVaults.delete(vaultId);
    }
  }

  private async undoLastEdit(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const operationId: string = this.requiredString(params, 'operationId');
    this.requireVault(vaultId);
    this.enterVault(vaultId);
    try {
      const records: AgentStoredOperation[] = this.storage.loadVaultOperations(vaultId);
      for (let i = 0; i < records.length; i++) {
        const record: AgentStoredOperation = records[i];
        if (record.conversationId === InsightIntentNoteService.CONVERSATION_ID) {
          await this.reconcileOperation(vaultId, record);
        }
      }
      const active: AgentStoredOperation[] = [];
      for (let i = 0; i < records.length; i++) {
        const record: AgentStoredOperation = records[i];
        if (record.conversationId === InsightIntentNoteService.CONVERSATION_ID && record.status === 'applied') {
          active.push(record);
        }
      }
      active.sort((a: AgentStoredOperation, b: AgentStoredOperation): number => b.createdAt - a.createdAt);
      if (active.length === 0) {
        throw new Error('NOTHING_TO_UNDO：当前知识库没有可撤销的小艺笔记操作。');
      }
      const record: AgentStoredOperation = active[0];
      if (record.operationId !== operationId) {
        throw new Error('NOT_LATEST_OPERATION：请撤销最近一次仍可撤销的小艺笔记操作。');
      }
      if (record.vaultKey !== this.registry.vaultKeyOf(vaultId)) {
        throw new Error('OUT_OF_SCOPE：该操作不属于指定知识库。');
      }
      if (record.path === '_wiki.md') {
        throw new Error('PATH_READONLY：小艺不能修改或撤销修改库规则文件。');
      }
      if (WorkspaceEditGuard.isUnsaved(vaultId, record.path)) {
        throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，不能撤销覆盖。');
      }
      const current: string | null = NoteService.tryReadNote(this.registry, vaultId, record.path);
      if (current === null || current !== record.after ||
        AgentOperationStorage.hashText(current) !== record.resultHash) {
        throw new Error('UNDO_CONFLICT：笔记已有后续修改，未覆盖当前内容。');
      }

      record.status = 'undoing';
      await this.storage.saveOperation(vaultId, record);
      try {
        if (record.created) {
          await NoteService.deleteNoteIfUnchanged(this.registry, vaultId, record.path, record.after);
        } else {
          await NoteService.saveNoteIfUnchanged(this.registry, vaultId, record.path, record.after, record.before);
        }
      } catch (error) {
        record.status = 'applied';
        await this.tryPersistOperation(vaultId, record);
        throw error as Error;
      }
      record.status = 'undone';
      await this.tryPersistOperation(vaultId, record);
      const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
      result['path'] = record.path;
      result['operationId'] = operationId;
      result['message'] = '已撤销知识库「' + vaultId + '」中「' + record.path + '」的最近一次小艺笔记操作。';
      return result;
    } finally {
      InsightIntentNoteService.busyVaults.delete(vaultId);
    }
  }

  private async applyExistingMutation(vaultId: string, toolName: string, path: string,
    before: string, after: string): Promise<Record<string, Object>> {
    this.requireAgentWritablePath(vaultId, path);
    if (WorkspaceEditGuard.isUnsaved(vaultId, path)) {
      throw new Error('UNSAVED_EDITOR：目标笔记出现未保存编辑，未写入。');
    }
    const record: AgentStoredOperation = await this.beginOperation(vaultId, toolName, path, before, after, false);
    try {
      await NoteService.saveNoteIfUnchanged(this.registry, vaultId, path, before, after);
    } catch (error) {
      await this.finishFailedOperation(vaultId, record);
      throw error as Error;
    }
    await this.finishAppliedOperation(vaultId, record);
    const result: Record<string, Object> = JSON.parse('{}') as Record<string, Object>;
    result['path'] = path;
    result['contentHash'] = record.resultHash;
    result['operationId'] = record.operationId;
    result['message'] = '已在知识库「' + vaultId + '」更新笔记「' + path + '」。';
    return result;
  }

  private async beginOperation(vaultId: string, toolName: string, path: string, before: string,
    after: string, created: boolean): Promise<AgentStoredOperation> {
    InsightIntentNoteService.serial++;
    const operationId: string = 'xiaoyi-' + Date.now().toString(36) + '-' +
      InsightIntentNoteService.serial.toString(36);
    const runId: string = operationId;
    const vaultKey: string = this.registry.vaultKeyOf(vaultId);
    const config: AgentRunConfig = {
      revision: 0,
      systemPrompt: '',
      promptRevision: '',
      skillId: 'xiaoyi',
      skillPrompt: '',
      enabledTools: [],
      allowedTools: []
    };
    const record: AgentStoredOperation = {
      schemaVersion: 1,
      vaultKey,
      conversationId: InsightIntentNoteService.CONVERSATION_ID,
      runId,
      operationId,
      toolName,
      signature: toolName + '|' + vaultId + '|' + path + '|' +
        AgentOperationStorage.hashText(before) + '|' + AgentOperationStorage.hashText(after),
      path,
      before,
      after,
      baseHash: AgentOperationStorage.hashText(before),
      resultHash: AgentOperationStorage.hashText(after),
      created,
      status: 'prepared',
      createdAt: Date.now()
    };
    await this.storage.beginRun(vaultId, InsightIntentNoteService.CONVERSATION_ID, runId, config, []);
    await this.storage.beginOperation(vaultId, record);
    return record;
  }

  private async finishAppliedOperation(vaultId: string, record: AgentStoredOperation): Promise<void> {
    record.status = 'applied';
    await this.tryPersistOperation(vaultId, record);
    await this.tryFinishRun(vaultId, record, 'completed');
  }

  private async finishFailedOperation(vaultId: string, record: AgentStoredOperation): Promise<void> {
    record.status = 'aborted';
    await this.tryPersistOperation(vaultId, record);
    await this.tryFinishRun(vaultId, record, 'failed');
  }

  private async reconcileOperation(vaultId: string, record: AgentStoredOperation): Promise<void> {
    if (record.status !== 'prepared' && record.status !== 'undoing') {
      return;
    }
    const exists: boolean = NoteService.exists(this.registry, vaultId, record.path);
    const current: string | null = exists ? NoteService.tryReadNote(this.registry, vaultId, record.path) : null;
    if (record.status === 'prepared') {
      if (current === record.after) {
        record.status = 'applied';
      } else if ((record.created && current === null) || (!record.created && current === record.before)) {
        record.status = 'aborted';
      } else {
        record.status = 'conflict';
      }
    } else if ((record.created && current === null) || (!record.created && current === record.before)) {
      record.status = 'undone';
    } else if (current === record.after) {
      record.status = 'applied';
    } else {
      record.status = 'conflict';
    }
    await this.tryPersistOperation(vaultId, record);
  }

  private async tryPersistOperation(vaultId: string, record: AgentStoredOperation): Promise<void> {
    try {
      await this.storage.saveOperation(vaultId, record);
    } catch (error) {
      // Prepared/undoing records are reconciled against the real note on the next tool call.
    }
  }

  private async tryFinishRun(vaultId: string, record: AgentStoredOperation, status: string): Promise<void> {
    try {
      await this.storage.finishRun(vaultId, record.conversationId, record.runId, status);
    } catch (error) {
      // The operation record is sufficient to recover the file result on the next tool call.
    }
  }

  private readExpectedVersion(vaultId: string, path: string, baseHash: string): string {
    const before: string | null = NoteService.tryReadNote(this.registry, vaultId, path);
    if (before === null) {
      throw new Error('READ_FAILED：笔记不存在或读取失败。');
    }
    if (AgentOperationStorage.hashText(before) !== baseHash) {
      throw new Error('STALE_CONTENT：笔记已变化，请重新读取后再决定下一步。');
    }
    return before;
  }

  private requireExistingNote(vaultId: string, path: string): void {
    const normalized: string = this.requireSafeNotePath(vaultId, path);
    const paths: string[] = FileTree.allNotesOf(this.registry.accessFor(vaultId));
    if (normalized !== path || paths.indexOf(path) < 0) {
      throw new Error('NOTE_NOT_FOUND：目标不是指定知识库中的可见 Markdown 笔记。');
    }
  }

  private requireSafeNotePath(vaultId: string, path: string): string {
    let normalized: string = '';
    try {
      normalized = NoteService.normalizeRelPath(path);
    } catch (error) {
      throw new Error('INVALID_PATH：请提供知识库内的 Markdown 相对路径。');
    }
    if (normalized !== path) {
      throw new Error('INVALID_PATH：路径必须是未经改写的知识库内 Markdown 相对路径。');
    }
    this.requireAllowedParent(vaultId, normalized);
    return normalized;
  }

  private requireAllowedParent(vaultId: string, path: string): void {
    const slash: number = path.lastIndexOf('/');
    const parent: string = slash >= 0 ? path.substring(0, slash) : '';
    if (parent.length === 0) {
      return;
    }
    const dirs: string[] = FileTree.allDirsOf(this.registry.accessFor(vaultId));
    if (dirs.indexOf(parent) < 0) {
      throw new Error('OUT_OF_SCOPE：目标目录不属于指定知识库或不存在。');
    }
  }

  private requireAgentWritablePath(vaultId: string, path: string): void {
    if (path === '_wiki.md') {
      throw new Error('PATH_READONLY：小艺不能修改库规则文件「_wiki.md」。');
    }
    if (!NoteService.exists(this.registry, vaultId, '_wiki.md')) {
      return;
    }
    const rules: string | null = NoteService.tryReadNote(this.registry, vaultId, '_wiki.md');
    if (rules === null) {
      throw new Error('WIKI_RULE_READ_FAILED：无法读取 _wiki.md，已拒绝写入。');
    }
    const folders: string[] = InsightIntentNoteService.parseReadOnlyFolders(rules);
    for (let i = 0; i < folders.length; i++) {
      if (InsightIntentNoteService.isReadOnlyPath(path, folders[i])) {
        throw new Error('PATH_READONLY：目标位于 _wiki.md 声明的只读目录。');
      }
    }
  }

  private requireVault(vaultId: string): void {
    if (vaultId.trim().length === 0) {
      throw new Error('INVALID_VAULT：必须明确提供知识库 ID。');
    }
    const entries = this.registry.list();
    let allowed: boolean = false;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].id === vaultId && (entries[i].type === 'local' || entries[i].type === 'git')) {
        allowed = true;
        break;
      }
    }
    if (!allowed) {
      throw new Error('OUT_OF_SCOPE：知识库 ID 不在 App 已注册的授权范围内。');
    }
  }

  private enterVault(vaultId: string): void {
    if (InsightIntentNoteService.busyVaults.has(vaultId)) {
      throw new Error('VAULT_BUSY：该知识库正在执行另一项小艺笔记操作。');
    }
    InsightIntentNoteService.busyVaults.add(vaultId);
  }

  private requiredString(params: Record<string, Object>, key: string, allowEmpty: boolean = false): string {
    const value: Object = params[key];
    if (typeof value !== 'string' || (!allowEmpty && (value as string).trim().length === 0)) {
      throw new Error('INVALID_PARAMETER：缺少有效参数「' + key + '」。');
    }
    return value as string;
  }

  /** 可选字符串参数：缺失、非字符串或空白都取缺省值。 */
  private optionalString(params: Record<string, Object>, key: string, fallback: string): string {
    const value: Object = params[key];
    if (typeof value !== 'string') {
      return fallback;
    }
    const trimmed: string = (value as string).trim();
    return trimmed.length === 0 ? fallback : trimmed;
  }

  /** vaultId 缺省解析：显式传入优先；否则用用户当前选择的知识库；两者皆无则拒绝执行。 */
  private static resolveVaultId(params: Record<string, Object>, currentVaultId: string): string {
    const provided: Object = params['vaultId'];
    if (typeof provided === 'string' && provided.trim().length > 0) {
      return provided.trim();
    }
    if (currentVaultId.length > 0) {
      return currentVaultId;
    }
    throw new Error('NO_CURRENT_VAULT：未指定 vaultId，且用户当前未选择知识库。');
  }

  private static appendText(before: string, addition: string): string {
    if (addition.length === 0) {
      throw new Error('EMPTY_WRITE：追加内容不能为空。');
    }
    if (before.length === 0) {
      return addition;
    }
    return before + (before.endsWith('\n') ? '' : '\n') + addition;
  }

  private static replaceUniqueAnchor(before: string, anchor: string, replacement: string): string {
    if (before.length === anchor.length && replacement.length === 0) {
      throw new Error('WHOLE_NOTE_DELETE_DENIED：不支持通过局部编辑删除整篇笔记。');
    }
    const start: number = before.indexOf(anchor);
    if (anchor.length === 0 || start < 0 || before.indexOf(anchor, start + anchor.length) >= 0) {
      throw new Error('ANCHOR_NOT_UNIQUE：原文锚点不存在或出现多次，未写入。');
    }
    return before.substring(0, start) + replacement + before.substring(start + anchor.length);
  }

  /** 分页上限：缺失取缺省；非正整数报 INVALID_ARGUMENT；超过 max 报 LIMIT_EXCEEDED。 */
  private static parseLimit(raw: Object, fallback: number, max: number, label: string): number {
    let text: string = '';
    if (typeof raw === 'string') {
      text = (raw as string).trim();
    } else if (typeof raw === 'number') {
      text = (raw as number).toString();
    } else if (raw !== undefined && raw !== null) {
      throw new Error('INVALID_ARGUMENT：' + label + ' 必须是正整数。');
    }
    if (text.length === 0) {
      return fallback;
    }
    const parsed: number = Number.parseInt(text, 10);
    if (Number.isNaN(parsed) || parsed <= 0) {
      throw new Error('INVALID_ARGUMENT：' + label + ' 必须是正整数。');
    }
    if (parsed > max) {
      throw new Error('LIMIT_EXCEEDED：' + label + ' 不得超过 ' + max.toString() + '。');
    }
    return parsed;
  }

  /** 分段起始偏移：必须是非负整数，缺省 0。 */
  private static parseOffset(raw: Object): number {
    let text: string = '';
    if (typeof raw === 'string') {
      text = (raw as string).trim();
    } else if (typeof raw === 'number') {
      text = (raw as number).toString();
    } else if (raw !== undefined && raw !== null) {
      throw new Error('INVALID_ARGUMENT：offset 必须是非负整数。');
    }
    if (text.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseInt(text, 10);
    if (Number.isNaN(parsed) || parsed < 0) {
      throw new Error('INVALID_ARGUMENT：offset 必须是非负整数。');
    }
    return parsed;
  }

  /** 游标是不透明字符串：解码失败要求模型从头翻页，不猜测含义。 */
  private static parseCursor(raw: Object): number {
    if (raw === undefined || raw === null) {
      return 0;
    }
    if (typeof raw !== 'string') {
      throw new Error('INVALID_ARGUMENT：cursor 无法识别，请重新从第一页开始。');
    }
    const text: string = (raw as string).trim();
    if (text.length === 0) {
      return 0;
    }
    if (!text.startsWith('xyo')) {
      throw new Error('INVALID_ARGUMENT：cursor 无法识别，请重新从第一页开始。');
    }
    const parsed: number = Number.parseInt(text.substring(3), 36);
    if (Number.isNaN(parsed) || parsed < 0) {
      throw new Error('INVALID_ARGUMENT：cursor 无法识别，请重新从第一页开始。');
    }
    return parsed;
  }

  private static encodeCursor(offset: number): string {
    return 'xyo' + offset.toString(36);
  }

  private static outputChars(result: Record<string, Object>): number {
    const keys: string[] = Object.keys(result);
    let total: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const value: Object = result[keys[i]];
      if (typeof value === 'string') {
        total += (value as string).length;
      }
    }
    return total;
  }

  private static ensureOutputBudget(result: Record<string, Object>): void {
    if (InsightIntentNoteService.outputChars(result) > XiaoyiToolLimits.outputBudgetChars) {
      throw new Error('OUTPUT_BUDGET_EXCEEDED：不可裁剪的返回信息超过本地输出上限。');
    }
  }

  private static fitJsonArrayCount(items: Object[], maxJsonChars: number): number {
    let low: number = 0;
    let high: number = items.length;
    while (low < high) {
      const middle: number = Math.ceil((low + high) / 2);
      const jsonChars: number = JSON.stringify(items.slice(0, middle)).length;
      if (jsonChars <= maxJsonChars) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  private static fitPage(items: Object[], start: number, limit: number, maxJsonChars: number,
    skipThresholdChars: number): PageSlice {
    const safeStart: number = Math.min(Math.max(start, 0), items.length);
    const candidates: Object[] = items.slice(safeStart, safeStart + limit);
    const count: number = InsightIntentNoteService.fitJsonArrayCount(candidates, maxJsonChars);
    const skippedCount: number = count === 0 && candidates.length > 0 &&
      JSON.stringify([candidates[0]]).length > skipThresholdChars ? 1 : 0;
    return {
      items: candidates.slice(0, count),
      nextIndex: safeStart + count + skippedCount,
      skippedCount: skippedCount
    };
  }

  private static fitChunkToOutputBudget(content: string, offset: number, length: number,
    fixedChars: number): ChunkPlan {
    const requested: ChunkPlan = InsightIntentNoteService.planChunk(content, offset, length);
    const available: number = Math.max(0, XiaoyiToolLimits.outputBudgetChars - fixedChars);
    if (requested.end - requested.start <= available) {
      return requested;
    }
    return InsightIntentNoteService.planChunk(content, requested.start, available);
  }

  /** Parse only the JSON-compatible YAML inline-list subset used by the readonly setting. */
  private static parseReadOnlyFolders(content: string): string[] {
    const source: string = content.replace(/^\uFEFF/, '');
    const lines: string[] = source.split(/\r?\n/);
    if (lines.length === 0 || lines[0].trim() !== '---') {
      return [];
    }
    let close: number = -1;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].trim() === '---' || lines[i].trim() === '...') {
        close = i;
        break;
      }
    }
    if (close < 0) {
      throw new Error('WIKI_RULE_INVALID：_wiki.md frontmatter 未闭合，已拒绝写入。');
    }
    let found: boolean = false;
    let raw: string = '';
    for (let i = 1; i < close; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.startsWith('#')) {
        continue;
      }
      const matched: RegExpMatchArray | null = line.match(/^readonly\s*:\s*(.*)$/);
      if (matched !== null) {
        if (found) {
          throw new Error('WIKI_RULE_INVALID：_wiki.md 的 readonly 配置重复，已拒绝写入。');
        }
        found = true;
        raw = matched[1].trim();
      } else if (line === 'readonly' || line.startsWith('readonly ') ||
        line.startsWith('readonly\t') || line.startsWith('"readonly"') || line.startsWith("'readonly'")) {
        throw new Error('WIKI_RULE_INVALID：_wiki.md 的 readonly 配置格式无效，已拒绝写入。');
      }
    }
    if (!found) {
      return [];
    }
    let value: Object;
    try {
      value = JSON.parse(raw) as Object;
    } catch (error) {
      throw new Error('WIKI_RULE_INVALID：readonly 仅支持 JSON 字符串数组，已拒绝写入。');
    }
    if (!Array.isArray(value)) {
      throw new Error('WIKI_RULE_INVALID：readonly 必须是字符串数组，已拒绝写入。');
    }
    const folders: string[] = [];
    const entries: Object[] = value as Object[];
    for (let i = 0; i < entries.length; i++) {
      if (typeof entries[i] !== 'string') {
        throw new Error('WIKI_RULE_INVALID：readonly 必须只包含目录路径，已拒绝写入。');
      }
      let folder: string = (entries[i] as string).trim();
      if (folder.endsWith('/')) {
        folder = folder.substring(0, folder.length - 1);
      }
      if (folder.length === 0 || folder.startsWith('/') || folder.indexOf('\\') >= 0) {
        throw new Error('WIKI_RULE_INVALID：readonly 包含无效目录路径，已拒绝写入。');
      }
      const segments: string[] = folder.split('/');
      for (let j = 0; j < segments.length; j++) {
        if (segments[j].length === 0 || segments[j] === '.' || segments[j] === '..' ||
          segments[j].startsWith('.')) {
          throw new Error('WIKI_RULE_INVALID：readonly 包含无效目录路径，已拒绝写入。');
        }
      }
      if (folders.indexOf(folder) < 0) {
        folders.push(folder);
      }
    }
    return folders;
  }

  private static isReadOnlyPath(path: string, folder: string): boolean {
    return path === folder || path.startsWith(folder + '/');
  }

  /** 以命中为中心的片段：命中词不被截断，超长用省略号标示。 */
  private static buildSnippet(content: string, matchAt: number, matchLength: number): string {
    if (matchAt < 0) {
      return '';
    }
    const max: number = XiaoyiToolLimits.snippetMaxChars;
    if (matchLength >= max || content.length <= max) {
      const head: string = content.length <= max ? content : content.substring(matchAt, matchAt + max);
      return (matchAt > 0 && content.length > max ? '…' : '') + head.replace(/\s+/g, ' ').trim() +
        (content.length > max ? '…' : '');
    }
    let start: number = matchAt - Math.floor((max - matchLength) / 2);
    if (start < 0) {
      start = 0;
    }
    let end: number = start + max;
    if (end > content.length) {
      end = content.length;
      start = Math.max(0, end - max);
    }
    const prefix: string = start > 0 ? '…' : '';
    const suffix: string = end < content.length ? '…' : '';
    return prefix + content.substring(start, end).replace(/\s+/g, ' ').trim() + suffix;
  }

  /** 行号从 1 起；offset 越界时按末尾计算。 */
  private static lineOfOffset(content: string, offset: number): number {
    let line: number = 1;
    const end: number = Math.min(offset, content.length);
    for (let i = 0; i < end; i++) {
      if (content.charAt(i) === '\n') {
        line++;
      }
    }
    return line;
  }

  /** 大纲：跳过 frontmatter 与围栏代码块内的标题，给出层级、行号与字符偏移。 */
  private static buildOutline(content: string): OutlineItem[] {
    const lines: string[] = content.split('\n');
    const items: OutlineItem[] = [];
    let offset: number = 0;
    let inFence: boolean = false;
    let inFrontmatter: boolean = false;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (i === 0 && trimmed === '---') {
        inFrontmatter = true;
        offset += line.length + 1;
        continue;
      }
      if (inFrontmatter) {
        if (trimmed === '---') {
          inFrontmatter = false;
        }
        offset += line.length + 1;
        continue;
      }
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        inFence = !inFence;
        offset += line.length + 1;
        continue;
      }
      if (!inFence) {
        const matched = line.match(/^(#{1,6})\s+(.*)$/);
        if (matched !== null) {
          items.push({ level: matched[1].length, title: matched[2].trim(), line: i + 1, offset: offset });
        }
      }
      offset += line.length + 1;
    }
    return items;
  }

  /** 分段切分：优先把结束点对齐到换行；没有换行可用时按字符硬切。 */
  private static planChunk(content: string, offset: number, length: number): ChunkPlan {
    const total: number = content.length;
    let start: number = offset < 0 ? 0 : offset;
    if (start > total) {
      start = total;
    }
    if (start > 0 && start < total) {
      const code: number = content.charCodeAt(start);
      if (code >= 0xDC00 && code <= 0xDFFF) {
        start = start - 1;
      }
    }
    let end: number = Math.min(total, start + length);
    if (end < total) {
      const newline: number = content.lastIndexOf('\n', end - 1);
      if (newline > start) {
        end = newline + 1;
      }
    }
    if (end > start && end < total) {
      const current: number = content.charCodeAt(end);
      const previous: number = content.charCodeAt(end - 1);
      if (current >= 0xDC00 && current <= 0xDFFF && previous >= 0xD800 && previous <= 0xDBFF) {
        end--;
      }
    }
    return { start: start, end: end, hasMore: end < total };
  }

  /** 目录浏览条目（纯逻辑）：目录先于笔记，各自按名称字典序，深度从起始目录的下一层起算。 */
  private static collectTreeEntries(dirs: string[], notes: string[], root: string,
    depth: number): TreeEntry[] {
    const prefix: string = root.length === 0 ? '' : root + '/';
    const entries: TreeEntry[] = [];
    for (let i = 0; i < dirs.length; i++) {
      const dir: string = dirs[i];
      if (!InsightIntentNoteService.withinDepth(dir, prefix, depth)) {
        continue;
      }
      entries.push({ path: dir, name: InsightIntentNoteService.lastSegment(dir), type: 'dir',
        depth: InsightIntentNoteService.relativeDepth(dir, prefix),
        childCount: InsightIntentNoteService.countNotesUnder(notes, dir), mtime: '' });
    }
    for (let i = 0; i < notes.length; i++) {
      const note: string = notes[i];
      if (!InsightIntentNoteService.withinDepth(note, prefix, depth)) {
        continue;
      }
      entries.push({ path: note, name: InsightIntentNoteService.lastSegment(note), type: 'note',
        depth: InsightIntentNoteService.relativeDepth(note, prefix), childCount: 0, mtime: '' });
    }
    entries.sort((left: TreeEntry, right: TreeEntry): number => {
      if (left.type !== right.type) {
        return left.type === 'dir' ? -1 : 1;
      }
      return compareVaultNames(left.path, right.path);
    });
    return entries;
  }

  private static withinDepth(path: string, prefix: string, depth: number): boolean {
    if (prefix.length > 0 && !path.startsWith(prefix)) {
      return false;
    }
    return InsightIntentNoteService.relativeDepth(path, prefix) <= depth;
  }

  private static relativeDepth(path: string, prefix: string): number {
    const rest: string = path.substring(prefix.length);
    let count: number = 1;
    for (let i = 0; i < rest.length; i++) {
      if (rest.charAt(i) === '/') {
        count++;
      }
    }
    return count;
  }

  private static countNotesUnder(notes: string[], dir: string): number {
    const prefix: string = dir + '/';
    let count: number = 0;
    for (let i = 0; i < notes.length; i++) {
      if (notes[i].startsWith(prefix)) {
        count++;
      }
    }
    return count;
  }

  /** 按目录前缀收窄候选；folder 为空表示整库。 */
  private static inFolder(paths: string[], folder: string): string[] {
    if (folder.length === 0) {
      return paths;
    }
    const prefix: string = folder + '/';
    const kept: string[] = [];
    for (let i = 0; i < paths.length; i++) {
      if (paths[i].startsWith(prefix)) {
        kept.push(paths[i]);
      }
    }
    return kept;
  }

  private static lastSegment(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  /** 只精确到天，避免把精确时间戳带进返回体。 */
  private static isoDate(seconds: number): string {
    return new Date(seconds * 1000).toISOString().substring(0, 10);
  }

  /** 反链上下文：引用所在行的原文片段，长度受 snippetMaxChars 限制。 */
  private static linkContext(source: string, sourcePath: string, targetPath: string,
    files: string[]): string {
    const references: WikiLinkReference[] = WikiLinkParser.parse(source);
    for (let i = 0; i < references.length; i++) {
      const reference: WikiLinkReference = references[i];
      const resolution: WikiLinkResolution = WikiLinkService.resolve(reference.target, sourcePath, files);
      if (resolution.status !== 'resolved' || resolution.path !== targetPath) {
        continue;
      }
      const start: number = source.lastIndexOf('\n', reference.start - 1) + 1;
      let end: number = source.indexOf('\n', reference.start);
      if (end < 0) {
        end = source.length;
      }
      const line: string = source.substring(start, end).trim();
      return line.length > XiaoyiToolLimits.snippetMaxChars
        ? line.substring(0, XiaoyiToolLimits.snippetMaxChars) : line;
    }
    return '';
  }
}
