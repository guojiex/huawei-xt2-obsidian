import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { atomicWriteText } from '../common/AtomicWrite';
import { AgentRunConfig, AgentNoteSnapshot } from './AgentModels';
import { VaultRegistry } from './VaultRegistry';

const AGENT_STORAGE_DOMAIN: number = 0x0000;
const AGENT_STORAGE_TAG: string = 'AgentOperationStorage';

export type AgentOperationStatus = 'prepared' | 'applied' | 'undoing' | 'undone' | 'aborted' | 'conflict';

export interface AgentStoredOperation {
  schemaVersion: number;
  vaultKey: string;
  conversationId: string;
  runId: string;
  operationId: string;
  toolName: string;
  signature: string;
  path: string;
  before: string;
  after: string;
  baseHash: string;
  resultHash: string;
  created: boolean;
  status: AgentOperationStatus;
  createdAt: number;
}

export interface AgentRunReference {
  path: string;
  contentHash: string;
}

export interface AgentRunState {
  schemaVersion: number;
  vaultKey: string;
  conversationId: string;
  runId: string;
  status: string;
  config: AgentRunConfig;
  references: AgentRunReference[];
  operationIds: string[];
  startedAt: number;
  updatedAt: number;
}

interface AgentStoredOperationRaw {
  schemaVersion?: Object;
  vaultKey?: Object;
  conversationId?: Object;
  runId?: Object;
  operationId?: Object;
  toolName?: Object;
  signature?: Object;
  path?: Object;
  before?: Object;
  after?: Object;
  baseHash?: Object;
  resultHash?: Object;
  created?: Object;
  status?: Object;
  createdAt?: Object;
}

export class AgentOperationStorage {
  private registry: VaultRegistry;

  constructor(registry: VaultRegistry) {
    this.registry = registry;
  }

  async beginRun(vaultId: string, conversationId: string, runId: string, config: AgentRunConfig,
    references: AgentNoteSnapshot[]): Promise<void> {
    const vaultKey: string = this.registry.vaultKeyOf(vaultId);
    this.ensureDirectory(this.registry.agentRunOperationsDirOf(vaultId, conversationId, runId));
    const state: AgentRunState = {
      schemaVersion: 1,
      vaultKey,
      conversationId,
      runId,
      status: 'running',
      config,
      references: references.map((item: AgentNoteSnapshot): AgentRunReference => {
        return { path: item.path, contentHash: item.contentHash };
      }),
      operationIds: [],
      startedAt: Date.now(),
      updatedAt: Date.now()
    };
    const statePath: string = this.registry.agentRunStateFileOf(vaultId, conversationId, runId);
    const serialized: string = JSON.stringify(state);
    await this.writeJson(statePath, serialized);
    const persisted: string = this.readText(statePath);
    hilog.info(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG, '运行状态读回校验完成');
    if (persisted !== serialized) {
      throw new Error('Agent 运行记录保存校验失败，未执行工具。');
    }
  }

  async finishRun(vaultId: string, conversationId: string, runId: string, status: string): Promise<void> {
    const path: string = this.registry.agentRunStateFileOf(vaultId, conversationId, runId);
    if (!fileIo.accessSync(path)) {
      return;
    }
    const state: AgentRunState | null = this.decodeRunState(this.readText(path),
      this.registry.vaultKeyOf(vaultId), conversationId, runId);
    if (state === null) {
      throw new Error('Agent 运行记录格式异常，已保留原文件。');
    }
    state.status = status;
    state.updatedAt = Date.now();
    await this.writeJson(path, JSON.stringify(state));
  }

  async beginOperation(vaultId: string, operation: AgentStoredOperation): Promise<void> {
    const statePath: string = this.registry.agentRunStateFileOf(
      vaultId, operation.conversationId, operation.runId);
    const raw: string = this.readText(statePath);
    const state: AgentRunState | null = this.decodeRunState(raw,
      this.registry.vaultKeyOf(vaultId), operation.conversationId, operation.runId);
    if (state === null) {
      try {
        JSON.parse(raw);
        hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG, '运行状态校验失败');
      } catch (_error) {
        hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG, '运行状态 JSON 无法解析');
      }
      throw new Error('Agent 运行记录格式异常，未执行笔记写入。');
    }
    if (state.status !== 'running') {
      hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG, '运行状态不是 running');
      throw new Error('Agent 运行记录不可用，未执行笔记写入。');
    }
    if (state.operationIds.indexOf(operation.operationId) < 0) {
      state.operationIds.push(operation.operationId);
      state.updatedAt = Date.now();
      await this.writeJson(statePath, JSON.stringify(state));
    }
    const path: string = this.registry.agentOperationFileOf(vaultId,
      operation.conversationId, operation.runId, operation.operationId);
    await this.writeJson(path, JSON.stringify(operation));
  }

  async saveOperation(vaultId: string, operation: AgentStoredOperation): Promise<void> {
    const path: string = this.registry.agentOperationFileOf(vaultId,
      operation.conversationId, operation.runId, operation.operationId);
    await this.writeJson(path, JSON.stringify(operation));
  }

  loadVaultOperations(vaultId: string): AgentStoredOperation[] {
    const root: string = this.registry.agentConversationsDirOf(vaultId);
    if (!fileIo.accessSync(root)) {
      return [];
    }
    const vaultKey: string = this.registry.vaultKeyOf(vaultId);
    const operations: AgentStoredOperation[] = [];
    const conversations: string[] = fileIo.listFileSync(root);
    for (let i = 0; i < conversations.length; i++) {
      const runsRoot: string = this.registry.agentRunsDirOf(vaultId, conversations[i]);
      if (!fileIo.accessSync(runsRoot)) {
        continue;
      }
      const runs: string[] = fileIo.listFileSync(runsRoot);
      for (let j = 0; j < runs.length; j++) {
        const operationsDir: string = this.registry.agentRunOperationsDirOf(vaultId, conversations[i], runs[j]);
        if (!fileIo.accessSync(operationsDir)) {
          continue;
        }
        const files: string[] = fileIo.listFileSync(operationsDir);
        for (let k = 0; k < files.length; k++) {
          if (!files[k].endsWith('.json')) {
            continue;
          }
          const operationId: string = files[k].substring(0, files[k].length - 5);
          const path: string = this.registry.agentOperationFileOf(vaultId, conversations[i], runs[j], operationId);
          try {
            const operation: AgentStoredOperation | null = AgentOperationStorage.decode(
              this.readText(path), vaultKey, conversations[i], runs[j], operationId);
            if (operation !== null) {
              operations.push(operation);
            }
          } catch (error) {
            // Keep unreadable records in place for later recovery.
          }
        }
      }
    }
    return operations;
  }

  static decode(raw: string, vaultKey: string, conversationId: string, runId: string,
    operationId: string): AgentStoredOperation | null {
    try {
      const value = JSON.parse(raw) as AgentStoredOperationRaw;
      if (typeof value !== 'object' || value === null || value.schemaVersion !== 1 || value.vaultKey !== vaultKey ||
        value.conversationId !== conversationId || value.runId !== runId || value.operationId !== operationId ||
        typeof value.toolName !== 'string' || typeof value.signature !== 'string' || typeof value.path !== 'string' ||
        typeof value.before !== 'string' || typeof value.after !== 'string' || typeof value.baseHash !== 'string' ||
        typeof value.resultHash !== 'string' || typeof value.created !== 'boolean' || typeof value.status !== 'string' ||
        typeof value.createdAt !== 'number') {
        return null;
      }
      if (value.status !== 'prepared' && value.status !== 'applied' && value.status !== 'undoing' &&
        value.status !== 'undone' && value.status !== 'aborted' && value.status !== 'conflict') {
        return null;
      }
      return {
        schemaVersion: 1,
        vaultKey,
        conversationId,
        runId,
        operationId,
        toolName: value.toolName,
        signature: value.signature,
        path: value.path,
        before: value.before,
        after: value.after,
        baseHash: value.baseHash,
        resultHash: value.resultHash,
        created: value.created,
        status: value.status as AgentOperationStatus,
        createdAt: value.createdAt
      };
    } catch (error) {
      return null;
    }
  }

  static decodeRunState(raw: string, vaultKey: string, conversationId: string,
    runId: string): AgentRunState | null {
    try {
      const state = JSON.parse(raw) as AgentRunState;
      if (typeof state !== 'object' || state === null || state.schemaVersion !== 1 || state.vaultKey !== vaultKey ||
        state.conversationId !== conversationId || state.runId !== runId || typeof state.status !== 'string' ||
        typeof state.config !== 'object' || state.config === null || !Array.isArray(state.references) ||
        !Array.isArray(state.operationIds) || typeof state.startedAt !== 'number' || typeof state.updatedAt !== 'number') {
        return null;
      }
      return state;
    } catch (error) {
      return null;
    }
  }

  static hashText(text: string): string {
    let hash: number = 2166136261;
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return (hash >>> 0).toString(16);
  }

  static reconcileStatus(operation: AgentStoredOperation, exists: boolean, current: string): AgentOperationStatus {
    const currentHash: string = exists ? AgentOperationStorage.hashText(current) : '';
    if (operation.status === 'prepared') {
      if (exists && currentHash === operation.resultHash && current === operation.after) {
        return 'applied';
      }
      if ((operation.created && !exists) || (!operation.created && exists && currentHash === operation.baseHash &&
        current === operation.before)) {
        return 'aborted';
      }
      return 'conflict';
    }
    if (operation.status === 'undoing') {
      if ((operation.created && !exists) || (!operation.created && exists && current === operation.before &&
        currentHash === operation.baseHash)) {
        return 'undone';
      }
      if (exists && current === operation.after && currentHash === operation.resultHash) {
        return 'applied';
      }
      return 'conflict';
    }
    return operation.status;
  }

  private decodeRunState(raw: string, vaultKey: string, conversationId: string,
    runId: string): AgentRunState | null {
    return AgentOperationStorage.decodeRunState(raw, vaultKey, conversationId, runId);
  }

  private readText(path: string): string {
    const byteLength: number = fileIo.statSync(path).size;
    return fileIo.readTextSync(path, { offset: 0, length: byteLength });
  }

  private ensureDirectory(path: string): void {
    if (fileIo.accessSync(path)) {
      return;
    }
    const slash: number = path.lastIndexOf('/');
    if (slash <= 0) {
      throw new Error('Agent 运行记录目录无效。');
    }
    const parent: string = path.substring(0, slash);
    if (!fileIo.accessSync(parent)) {
      this.ensureDirectory(parent);
    }
    fileIo.mkdirSync(path);
  }

  /**
   * 写入 + 写后读回校验（2026-11-11 Z4 引入）：
   * 写本体走公共 atomicWriteText（finishWrite 完成才 resolve）；此后再轮询读回比对，
   * 超时只报错**不回滚** —— finishWrite 已完成，文件已是权威内容，回滚反而会丢写。
   */
  private writeJson(path: string, content: string): Promise<void> {
    const recordKind: string = path.endsWith('/state.json') ? 'run-state' : 'operation-record';
    return atomicWriteText(path, content, { timeoutMessage: 'Agent 操作账 AtomicFile 写入超时' })
      .then((): Promise<void> => this.verifyPersisted(path, content))
      .catch((error: Error): Promise<void> => {
        hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
          'AtomicFile 写入失败 kind=%{public}s', recordKind);
        throw error;
      });
  }

  /** finishWrite 后间歇性读到旧内容（API26 x86_64 模拟器实测）：50ms 轮询重试，3s 截止。 */
  private verifyPersisted(path: string, content: string,
    deadline: number = Date.now() + 3000): Promise<void> {
    try {
      if (this.readText(path) === content) {
        return Promise.resolve();
      }
    } catch (error) {
      // 提交后的读回可能瞬时失败：重试到截止时间。
    }
    if (Date.now() >= deadline) {
      return Promise.reject(new Error('Agent 操作账 AtomicFile 写入后读回超时'));
    }
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => { resolve(); }, 50);
    }).then((): Promise<void> => this.verifyPersisted(path, content, deadline));
  }
}
