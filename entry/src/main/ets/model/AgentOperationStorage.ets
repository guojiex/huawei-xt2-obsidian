import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
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
    hilog.info(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
      '运行状态读回校验 serializedChars=%{public}d persistedChars=%{public}d',
      serialized.length, persisted.length);
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
        const rawState: AgentRunState = JSON.parse(raw) as AgentRunState;
        const vaultMatches: string = rawState.vaultKey === this.registry.vaultKeyOf(vaultId) ? 'true' : 'false';
        const conversationMatches: string = rawState.conversationId === operation.conversationId ? 'true' : 'false';
        const runMatches: string = rawState.runId === operation.runId ? 'true' : 'false';
        hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
          '运行状态校验失败 schema=%{public}d vault=%{public}s conversation=%{public}s run=%{public}s status=%{public}s',
          rawState.schemaVersion, vaultMatches, conversationMatches, runMatches, rawState.status);
      } catch (error) {
        const rawLength: number = raw.length;
        const firstCode: number = rawLength > 0 ? raw.charCodeAt(0) : -1;
        const lastCode: number = rawLength > 0 ? raw.charCodeAt(rawLength - 1) : -1;
        hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
          '运行状态 JSON 无法解析 chars=%{public}d first=%{public}d last=%{public}d',
          rawLength, firstCode, lastCode);
      }
      throw new Error('Agent 运行记录格式异常，未执行笔记写入。');
    }
    if (state.status !== 'running') {
      hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG, '运行状态不是 running: %{public}s', state.status);
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

  private writeJson(path: string, content: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(path);
      const recordKind: string = path.endsWith('/state.json') ? 'run-state' : 'operation-record';
      let settled: boolean = false;
      let writeFinished: boolean = false;
      let timerId: number = -1;
      const fail = (message: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        if (!writeFinished) {
          try {
            atomicFile.failWrite();
          } catch (error) {
            // Keep the original write error.
          }
        }
        reject(new Error(message));
      };
      const finish = (): void => {
        if (settled) {
          return;
        }
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.finishWrite();
          writeFinished = true;
        } catch (error) {
          const err = error as BusinessError;
          hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
            'AtomicFile finishWrite 失败 kind=%{public}s', recordKind);
          fail(err.message);
          return;
        }
        const deadline: number = Date.now() + 3000;
        const verifyReadBack = (): void => {
          if (settled) {
            return;
          }
          try {
            const persisted: string = this.readText(path);
            if (persisted === content) {
              settled = true;
              if (timerId !== -1) {
                clearTimeout(timerId);
              }
              resolve();
              return;
            }
          } catch (error) {
            // Retry until the committed file becomes visible, or fail without rolling back a finished write.
          }
          if (Date.now() >= deadline) {
            fail('Agent 操作账 AtomicFile 写入后读回超时');
            return;
          }
          timerId = setTimeout(verifyReadBack, 50);
        };
        verifyReadBack();
      };
      try {
        const stream: fileIo.WriteStream = atomicFile.startWrite();
        hilog.info(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
          'AtomicFile startWrite 完成 kind=%{public}s', recordKind);
        timerId = setTimeout((): void => { fail('Agent 操作账 AtomicFile 写入超时'); }, 3000);
        if (content.length === 0) {
          finish();
        } else {
          stream.write(content, 'utf-8', (err?: BusinessError): void => {
            if (err !== undefined && err !== null) {
              hilog.error(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
                'AtomicFile write 回调失败 kind=%{public}s', recordKind);
              fail(err.message);
              return;
            }
            hilog.info(AGENT_STORAGE_DOMAIN, AGENT_STORAGE_TAG,
              'AtomicFile write 回调成功 kind=%{public}s', recordKind);
            finish();
          });
        }
      } catch (error) {
        const err = error as BusinessError;
        fail(err.message);
      }
    });
  }
}
