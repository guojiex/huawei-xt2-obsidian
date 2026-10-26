import { FileTree, TreeNode } from './FileTree';
import { NoteService } from './NoteService';
import { VaultRegistry } from './VaultRegistry';
import {
  AgentMessage, AgentMessagePart, AgentNoteSnapshot, AgentRunConfig, AgentScenario,
  AgentSession, AgentToolEvent, AgentToolStep, AgentWriteResult
} from './AgentModels';
import { AgentRules } from './AgentRules';
import { AGENT_MOCK_SCENARIOS } from './AgentDefaults';

interface StoredOperation {
  signature: string;
  result: AgentWriteResult;
}

export class AgentRuntime {
  private static serial: number = 0;
  private static readonly MAX_TOOL_STEPS: number = 12;
  private static operations: Map<string, StoredOperation> = new Map<string, StoredOperation>();
  private static operationOrderByVault: Map<string, string[]> = new Map<string, string[]>();
  private static latestOperationByVault: Map<string, string> = new Map<string, string>();
  private static runningSessions: Set<string> = new Set<string>();
  private static runningVaults: Set<string> = new Set<string>();

  static newRunId(): string {
    AgentRuntime.serial++;
    return Date.now().toString() + '-' + AgentRuntime.serial.toString();
  }

  static captureReferences(vaultId: string, parts: AgentMessagePart[], registry: VaultRegistry,
    isUnsaved: (path: string) => boolean): AgentNoteSnapshot[] {
    const snapshots: AgentNoteSnapshot[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < parts.length; i++) {
      const part: AgentMessagePart = parts[i];
      if (part.kind !== 'note_ref') {
        continue;
      }
      if (part.vaultId !== vaultId) {
        throw new Error('OUT_OF_SCOPE：引用不属于当前知识库。');
      }
      let normalizedPath: string = '';
      try {
        normalizedPath = NoteService.normalizeRelPath(part.path);
      } catch (error) {
        throw new Error('INVALID_REFERENCE：引用路径无效，请从文件树重新选择。');
      }
      if (normalizedPath !== part.path) {
        throw new Error('INVALID_REFERENCE：引用路径必须是库内 Markdown 相对路径。');
      }
      if (seen.has(part.path)) {
        continue;
      }
      if (isUnsaved(part.path)) {
        throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，请先保存再引用。');
      }
      if (!NoteService.exists(registry, vaultId, part.path)) {
        throw new Error('STALE_REFERENCE：引用笔记已移除或改名，请重新选择。');
      }
      const content: string | null = NoteService.tryReadNote(registry, vaultId, part.path);
      if (content === null) {
        throw new Error('READ_FAILED：引用笔记读取失败，草稿已保留。');
      }
      snapshots.push({ vaultId, path: part.path, content, contentHash: AgentRuntime.hashText(content) });
      seen.add(part.path);
    }
    return snapshots;
  }

  static referenceStillValid(vaultId: string, snapshot: AgentNoteSnapshot, registry: VaultRegistry): boolean {
    if (snapshot.vaultId !== vaultId || !NoteService.exists(registry, vaultId, snapshot.path)) {
      return false;
    }
    const current: string | null = NoteService.tryReadNote(registry, vaultId, snapshot.path);
    return current !== null && current === snapshot.content && AgentRuntime.hashText(current) === snapshot.contentHash;
  }

  static async run(vaultId: string, session: AgentSession, runId: string, rawText: string, parts: AgentMessagePart[],
    references: AgentNoteSnapshot[], config: AgentRunConfig, registry: VaultRegistry,
    isUnsaved: (path: string) => boolean): Promise<AgentMessage> {
    const runKey: string = vaultId + ':' + session.id;
    if (AgentRuntime.runningSessions.has(runKey) || AgentRuntime.runningVaults.has(vaultId)) {
      throw new Error('当前知识库已有一轮运行，请等待完成后再发送。');
    }
    for (let i = 0; i < session.messages.length; i++) {
      if (session.messages[i].id === 'assistant-' + runId) {
        return session.messages[i];
      }
    }
    AgentRuntime.runningSessions.add(runKey);
    AgentRuntime.runningVaults.add(vaultId);
    try {
      const userMessage: AgentMessage = {
        id: 'user-' + runId,
        role: 'user',
        parts,
        references: references.slice(),
        toolEvents: [],
        writeResult: null,
        configRevision: config.revision,
        skillId: config.skillId,
        createdAt: Date.now()
      };
      if (session.titleManuallySet !== true && session.title === '新对话') {
        const title: string = AgentRules.commandText(parts);
        session.title = title.length > 24 ? title.substring(0, 24) : title;
      }
      session.messages.push(userMessage);

      const assistant: AgentMessage = {
        id: 'assistant-' + runId,
        role: 'assistant',
        parts: [],
        references: references.slice(),
        toolEvents: [],
        writeResult: null,
        configRevision: config.revision,
        skillId: config.skillId,
        createdAt: Date.now()
      };
      session.messages.push(assistant);

      const scenario: AgentScenario | null = AgentRules.scenarioFor(parts, AGENT_MOCK_SCENARIOS);
      if (scenario === null) {
        AgentRuntime.setAssistantText(assistant,
          '没有匹配本地固定 mock 场景；不会调用工具。当前支持：' + AgentRuntime.supportedQuestions() + '。');
        return assistant;
      }
      if (scenario.tools.length > AgentRuntime.MAX_TOOL_STEPS) {
        AgentRuntime.setAssistantText(assistant, '执行失败：工具步骤超过本轮预算；没有开始执行。');
        return assistant;
      }

      const readPaths: Set<string> = new Set<string>();
      for (let i = 0; i < scenario.tools.length; i++) {
        const step: AgentToolStep = scenario.tools[i];
        const event: AgentToolEvent = {
          name: step.name,
          status: 'failed',
          result: '',
          errorCode: '',
          operationId: ''
        };
        assistant.toolEvents.push(event);
        try {
          AgentRules.validateStep(step);
          AgentRuntime.assertToolAllowed(step.name, config);
          event.operationId = AgentRuntime.operationId(vaultId, runId, i);
          const result: string = await AgentRuntime.executeStep(vaultId, session, assistant, step,
            references, config, registry, readPaths, isUnsaved, event.operationId);
          event.status = 'completed';
          event.result = result;
        } catch (error) {
          const err = error as Error;
          event.errorCode = AgentRuntime.errorCode(err.message);
          event.result = err.message;
          AgentRuntime.setAssistantText(assistant, '执行未完成：' + err.message + ' 已成功步骤保留在记录中，未跳过限制或伪造结果。');
          return assistant;
        }
      }
      AgentRuntime.setAssistantText(assistant, scenario.reply);
      return assistant;
    } finally {
      AgentRuntime.runningSessions.delete(runKey);
      AgentRuntime.runningVaults.delete(vaultId);
    }
  }

  static async undoLast(vaultId: string, session: AgentSession, config: AgentRunConfig,
    registry: VaultRegistry, isUnsaved: (path: string) => boolean): Promise<AgentWriteResult> {
    AgentRuntime.assertToolAllowed('UndoLastEdit', config);
    const opId: string | undefined = AgentRuntime.latestActiveOperation(vaultId);
    if (opId === undefined) {
      throw new Error('NOTHING_TO_UNDO：当前知识库没有可撤销操作。');
    }
    return AgentRuntime.undoOperation(vaultId, session, opId, registry, isUnsaved);
  }

  private static async undoOperation(vaultId: string, session: AgentSession, opId: string,
    registry: VaultRegistry, isUnsaved: (path: string) => boolean): Promise<AgentWriteResult> {
    const stored: StoredOperation | undefined = AgentRuntime.operations.get(opId);
    if (stored === undefined || stored.result.vaultId !== vaultId) {
      throw new Error('NOTHING_TO_UNDO：最近一次操作已撤销或不属于当前知识库。');
    }
    const result: AgentWriteResult = stored.result;
    if (result.undone) {
      return result;
    }
    if (isUnsaved(result.path)) {
      throw new Error('UNSAVED_EDITOR：目标仍有未保存编辑，不能撤销覆盖。');
    }
    if (!NoteService.exists(registry, vaultId, result.path)) {
      throw new Error('UNDO_CONFLICT：目标笔记已移除或改名，未撤销。');
    }
    const current: string | null = NoteService.tryReadNote(registry, vaultId, result.path);
    if (current === null || current !== result.after) {
      throw new Error('UNDO_CONFLICT：笔记已有后续修改，未覆盖当前内容。');
    }
    if (result.created) {
      await NoteService.deletePath(registry, vaultId, result.path);
    } else {
      await NoteService.saveNote(registry, vaultId, result.path, result.before);
    }
    result.undone = true;
    AgentRuntime.refreshLatestOperation(vaultId);
    for (let i = session.messages.length - 1; i >= 0; i--) {
      if (session.messages[i].writeResult !== null &&
        (session.messages[i].writeResult as AgentWriteResult).operationId === opId) {
        (session.messages[i].writeResult as AgentWriteResult).undone = true;
        break;
      }
    }
    return result;
  }

  static async executeManualStep(vaultId: string, session: AgentSession, message: AgentMessage,
    step: AgentToolStep, config: AgentRunConfig, registry: VaultRegistry,
    isUnsaved: (path: string) => boolean): Promise<AgentWriteResult> {
    AgentRules.validateStep(step);
    AgentRuntime.assertToolAllowed(step.name, config);
    if (step.name !== 'UndoLastEdit') {
      throw new Error('该结果卡不支持手动重放工具步骤。');
    }
    if (message.writeResult === null) {
      throw new Error('该消息没有可撤销的写入结果。');
    }
    const result: AgentWriteResult = message.writeResult as AgentWriteResult;
    if (result.vaultId !== vaultId) {
      throw new Error('OUT_OF_SCOPE：该写入不属于当前知识库。');
    }
    return AgentRuntime.undoOperation(vaultId, session, result.operationId, registry, isUnsaved);
  }

  private static async executeStep(vaultId: string, session: AgentSession, assistant: AgentMessage,
    step: AgentToolStep, references: AgentNoteSnapshot[], config: AgentRunConfig,
    registry: VaultRegistry, readPaths: Set<string>, isUnsaved: (path: string) => boolean,
    operationId: string): Promise<string> {
    if (step.name === 'QueryNotes') {
      const query: string = step.query ?? '';
      const paths: string[] = AgentRuntime.listMarkdownPaths(registry, vaultId);
      const matches: string[] = [];
      for (let i = 0; i < paths.length; i++) {
        if (paths[i].toLocaleLowerCase().indexOf(query.toLocaleLowerCase()) >= 0) {
          matches.push(paths[i]);
        }
      }
      return matches.length > 0 ? matches.join('\n') : '没有匹配的笔记。';
    }
    if (step.name === 'ReadNote') {
      if (references.length === 0) {
        throw new Error('NO_REFERENCE：先从当前知识库选择要读取的笔记。');
      }
      let output: string = '';
      for (let i = 0; i < references.length; i++) {
        const snapshot: AgentNoteSnapshot = references[i];
        if (snapshot.vaultId !== vaultId) {
          throw new Error('OUT_OF_SCOPE：引用不属于当前知识库。');
        }
        if (isUnsaved(snapshot.path)) {
          throw new Error('UNSAVED_EDITOR：编辑器仍有未保存内容。');
        }
        const current: string | null = NoteService.tryReadNote(registry, vaultId, snapshot.path);
        if (current === null) {
          throw new Error('STALE_REFERENCE：引用笔记已移除或无法读取。');
        }
        if (current !== snapshot.content || AgentRuntime.hashText(current) !== snapshot.contentHash) {
          throw new Error('STALE_CONTENT：引用后笔记有变化，请重新引用后再发送。');
        }
        readPaths.add(snapshot.path);
        output += (i === 0 ? '' : '\n\n') + snapshot.path + '\n' + current;
      }
      return output;
    }
    if (step.name === 'AppendNote' || step.name === 'EditNote') {
      const snapshot: AgentNoteSnapshot = AgentRuntime.singleTarget(references, vaultId);
      if (!readPaths.has(snapshot.path)) {
        throw new Error('READ_BEFORE_WRITE：本轮必须先成功读取目标笔记。');
      }
      const current: string | null = NoteService.tryReadNote(registry, vaultId, snapshot.path);
      if (current === null || current !== snapshot.content ||
        AgentRuntime.hashText(current) !== snapshot.contentHash) {
        throw new Error('STALE_CONTENT：写入前版本已变化，请重新读取并发送。');
      }
      if (isUnsaved(snapshot.path)) {
        throw new Error('UNSAVED_EDITOR：目标笔记仍有未保存编辑，未写入。');
      }
      const after: string = step.name === 'AppendNote'
        ? AgentRuntime.appendText(current, step.text ?? '')
        : AgentRuntime.replaceUnique(current, step.anchor ?? '', step.text ?? '');
      const signature: string = step.name + '|' + vaultId + '|' + snapshot.path + '|' +
        (step.anchor ?? '') + '|' + (step.text ?? '');
      const replay: boolean = AgentRuntime.operations.has(operationId);
      const result: AgentWriteResult = await AgentRuntime.writeExisting(operationId, signature,
        vaultId, snapshot.path, current, after, registry);
      assistant.writeResult = result;
      return replay ? '相同操作已执行过，没有重复写入。实际路径：' + result.path
        : '已写入 ' + result.path + '。';
    }
    if (step.name === 'CreateNote') {
      const requestedPath: string = step.path ?? '';
      if (requestedPath.length === 0 || NoteService.normalizeRelPath(requestedPath) !== requestedPath) {
        throw new Error('INVALID_PATH：固定场景没有提供有效的库内目标路径。');
      }
      const text: string = step.text ?? '';
      const signature: string = 'CreateNote|' + vaultId + '|' + requestedPath + '|' + text;
      const existing: StoredOperation | undefined = AgentRuntime.operations.get(operationId);
      if (existing !== undefined) {
        if (existing.signature !== signature) {
          throw new Error('OPERATION_REPLAY_MISMATCH：相同 operationId 对应了不同参数。');
        }
        assistant.writeResult = existing.result;
        return '已登记相同 operationId；未重复创建或写入。实际路径：' + existing.result.path;
      }
      const actualPath: string = NoteService.createNote(registry, vaultId, requestedPath);
      try {
        await NoteService.saveNote(registry, vaultId, actualPath, text);
      } catch (error) {
        if (NoteService.exists(registry, vaultId, actualPath) &&
          NoteService.tryReadNote(registry, vaultId, actualPath) === '') {
          try {
            await NoteService.deletePath(registry, vaultId, actualPath);
          } catch (cleanupError) {
            // 保留原始写入错误；空文件不会被报告为成功。
          }
        }
        const err: Error = error as Error;
        throw err;
      }
      const result: AgentWriteResult = {
        operationId,
        vaultId,
        path: actualPath,
        before: '',
        after: text,
        created: true,
        undone: false
      };
      AgentRuntime.recordOperation(operationId, signature, result);
      assistant.writeResult = result;
      return '已创建 ' + actualPath + '。';
    }
    if (step.name === 'UndoLastEdit') {
      const result: AgentWriteResult = await AgentRuntime.undoLast(vaultId, session, config, registry, isUnsaved);
      return '已撤销 ' + result.path + '；文件当前版本通过了冲突校验。';
    }
    throw new Error('UNKNOWN_TOOL：不支持的本地工具。');
  }

  private static async writeExisting(operationId: string, signature: string, vaultId: string, path: string,
    before: string, after: string, registry: VaultRegistry): Promise<AgentWriteResult> {
    const existing: StoredOperation | undefined = AgentRuntime.operations.get(operationId);
    if (existing !== undefined) {
      if (existing.signature !== signature) {
        throw new Error('OPERATION_REPLAY_MISMATCH：相同 operationId 对应了不同参数。');
      }
      return existing.result;
    }
    await NoteService.saveNote(registry, vaultId, path, after);
    const result: AgentWriteResult = { operationId, vaultId, path, before, after, created: false, undone: false };
    AgentRuntime.recordOperation(operationId, signature, result);
    return result;
  }

  private static recordOperation(operationId: string, signature: string, result: AgentWriteResult): void {
    AgentRuntime.operations.set(operationId, { signature, result });
    const order: string[] = AgentRuntime.operationOrderByVault.get(result.vaultId) ?? [];
    if (order.indexOf(operationId) < 0) {
      order.push(operationId);
      AgentRuntime.operationOrderByVault.set(result.vaultId, order);
    }
    AgentRuntime.latestOperationByVault.set(result.vaultId, operationId);
  }

  private static latestActiveOperation(vaultId: string): string | undefined {
    const order: string[] = AgentRuntime.operationOrderByVault.get(vaultId) ?? [];
    for (let i = order.length - 1; i >= 0; i--) {
      const stored: StoredOperation | undefined = AgentRuntime.operations.get(order[i]);
      if (stored !== undefined && !stored.result.undone) {
        return order[i];
      }
    }
    return undefined;
  }

  private static refreshLatestOperation(vaultId: string): void {
    const latest: string | undefined = AgentRuntime.latestActiveOperation(vaultId);
    if (latest === undefined) {
      AgentRuntime.latestOperationByVault.delete(vaultId);
    } else {
      AgentRuntime.latestOperationByVault.set(vaultId, latest);
    }
  }

  private static operationId(vaultId: string, runId: string, index: number): string {
    return 'agent:' + vaultId + ':' + runId + ':' + index.toString();
  }

  private static singleTarget(references: AgentNoteSnapshot[], vaultId: string): AgentNoteSnapshot {
    if (references.length !== 1) {
      throw new Error(references.length === 0
        ? 'NO_REFERENCE：先选择目标笔记。'
        : 'AMBIGUOUS_TARGET：本轮引用了多篇笔记；请明确为单一目标后再写入。');
    }
    if (references[0].vaultId !== vaultId) {
      throw new Error('OUT_OF_SCOPE：目标不属于当前知识库。');
    }
    return references[0];
  }

  private static assertToolAllowed(name: string, config: AgentRunConfig): void {
    if (!AgentRules.toolAllowed(name, config.enabledTools, config.allowedTools)) {
      throw new Error('PERMISSION_DENIED：当前工具开关或 Skill 不允许 ' + name + '。');
    }
  }

  private static listMarkdownPaths(registry: VaultRegistry, vaultId: string): string[] {
    const root: string = registry.vaultDirOf(vaultId);
    let expanded: string[] = [];
    const found: Map<string, TreeNode> = new Map<string, TreeNode>();
    for (let pass = 0; pass < 64; pass++) {
      const nodes: TreeNode[] = FileTree.scan(root, expanded);
      let changed: boolean = false;
      for (let i = 0; i < nodes.length; i++) {
        const node: TreeNode = nodes[i];
        found.set(node.relPath, node);
        if (node.isDir && expanded.indexOf(node.relPath) < 0) {
          expanded.push(node.relPath);
          changed = true;
        }
      }
      if (!changed) {
        break;
      }
    }
    const paths: string[] = [];
    found.forEach((node: TreeNode, path: string): void => {
      if (!node.isDir && (path.toLowerCase().endsWith('.md') || path.toLowerCase().endsWith('.markdown'))) {
        paths.push(path);
      }
    });
    paths.sort();
    return paths;
  }

  private static appendText(before: string, addition: string): string {
    if (addition.length === 0) {
      throw new Error('EMPTY_WRITE：追加内容不能为空。');
    }
    if (before.length === 0) {
      return addition;
    }
    const separator: string = before.endsWith('\n') ? '' : '\n';
    return before + separator + addition;
  }

  private static replaceUnique(before: string, anchor: string, replacement: string): string {
    const range: number[] = AgentRules.uniqueAnchorRange(before, anchor);
    return before.substring(0, range[0]) + replacement + before.substring(range[1]);
  }

  private static supportedQuestions(): string {
    const questions: string[] = [];
    for (let i = 0; i < AGENT_MOCK_SCENARIOS.length; i++) {
      for (let j = 0; j < AGENT_MOCK_SCENARIOS[i].inputs.length; j++) {
        questions.push(AGENT_MOCK_SCENARIOS[i].inputs[j]);
      }
    }
    return questions.join('、');
  }

  static fixedQuestions(): string[] {
    const questions: string[] = [];
    for (let i = 0; i < AGENT_MOCK_SCENARIOS.length; i++) {
      for (let j = 0; j < AGENT_MOCK_SCENARIOS[i].inputs.length; j++) {
        questions.push(AGENT_MOCK_SCENARIOS[i].inputs[j]);
      }
    }
    return questions;
  }

  private static setAssistantText(message: AgentMessage, text: string): void {
    message.parts = [{ kind: 'text', text, path: '', vaultId: '' }];
  }

  private static errorCode(message: string): string {
    const colon: number = message.indexOf('：');
    return colon > 0 ? message.substring(0, colon) : 'TOOL_FAILED';
  }

  private static hashText(text: string): string {
    let hash: number = 2166136261;
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }
}
