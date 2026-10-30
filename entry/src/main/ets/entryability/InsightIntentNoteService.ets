import { AgentOperationStorage, AgentOperationStatus, AgentStoredOperation } from '../model/AgentOperationStorage';
import { AgentRunConfig } from '../model/AgentModels';
import { FileTree } from '../model/FileTree';
import { NoteService } from '../model/NoteService';
import { VaultRegistry } from '../model/VaultRegistry';
import { WorkspaceEditGuard } from '../model/WorkspaceEditGuard';

interface NoteMatch {
  name: string;
  path: string;
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
    const paths: string[] = FileTree.allMarkdownFiles(this.registry.vaultDirOf(vaultId));
    const matches: NoteMatch[] = [];
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
    result['message'] = '在知识库「' + vaultId + '」找到 ' + matches.length.toString() + ' 篇候选笔记。';
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
    result['content'] = content;
    result['contentHash'] = AgentOperationStorage.hashText(content);
    result['path'] = path;
    result['message'] = '已读取知识库「' + vaultId + '」中的「' + path + '」。';
    return result;
  }

  private async createNote(params: Record<string, Object>): Promise<Record<string, Object>> {
    const vaultId: string = InsightIntentNoteService.resolveVaultId(params, this.registry.currentId());
    const requestedPath: string = this.requiredString(params, 'path');
    const content: string = this.requiredString(params, 'text', true);
    this.requireVault(vaultId);
    const normalizedPath: string = this.requireSafeNotePath(vaultId, requestedPath);
    this.requireAllowedParent(vaultId, normalizedPath);
    this.enterVault(vaultId);
    try {
      const path: string = NoteService.previewCreatePath(this.registry, vaultId, normalizedPath);
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
    const paths: string[] = FileTree.allMarkdownFiles(this.registry.vaultDirOf(vaultId));
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
    const dirs: string[] = FileTree.allDirs(this.registry.vaultDirOf(vaultId));
    if (dirs.indexOf(parent) < 0) {
      throw new Error('OUT_OF_SCOPE：目标目录不属于指定知识库或不存在。');
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
}
