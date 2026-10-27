import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { AgentMessage, AgentSession } from './AgentModels';
import { VaultRegistry } from './VaultRegistry';

interface AgentConversationDocument {
  schemaVersion: number;
  vaultKey: string;
  session: AgentSession;
}

interface AgentConversationRaw {
  schemaVersion?: Object;
  vaultKey?: Object;
  session?: Object;
}

interface AgentSessionRaw {
  id?: Object;
  vaultId?: Object;
  title?: Object;
  titleManuallySet?: Object;
  archived?: Object;
  skillId?: Object;
  draft?: Object;
  messages?: Object;
  updatedAt?: Object;
}

export class AgentConversationStorage {
  private registry: VaultRegistry;
  private writeChains: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  constructor(registry: VaultRegistry) {
    this.registry = registry;
  }

  load(vaultId: string): AgentSession[] {
    const root: string = this.registry.agentConversationsDirOf(vaultId);
    if (!fileIo.accessSync(root)) {
      return [];
    }
    const ids: string[] = fileIo.listFileSync(root);
    const sessions: AgentSession[] = [];
    for (let i = 0; i < ids.length; i++) {
      try {
        const path: string = this.registry.agentConversationFileOf(vaultId, ids[i]);
        if (!fileIo.accessSync(path)) {
          continue;
        }
        const raw: string = fileIo.readTextSync(path, { offset: 0 });
        const session: AgentSession | null = AgentConversationStorage.decode(
          raw, this.registry.vaultKeyOf(vaultId), vaultId, ids[i]);
        if (session !== null) {
          sessions.push(session);
        }
      } catch (error) {
        // Keep unreadable or malformed private data in place for later recovery.
      }
    }
    sessions.sort((a: AgentSession, b: AgentSession): number => {
      return (b.updatedAt ?? 0) - (a.updatedAt ?? 0);
    });
    return sessions;
  }

  save(vaultId: string, session: AgentSession): Promise<void> {
    const key: string = this.registry.agentConversationFileOf(vaultId, session.id);
    const pending: Promise<void> | undefined = this.writeChains.get(key);
    const previous: Promise<void> = pending === undefined ? Promise.resolve() : pending;
    const job: Promise<void> = previous.then((): Promise<void> => {
      session.updatedAt = Date.now();
      const json: string = AgentConversationStorage.encode(session, this.registry.vaultKeyOf(vaultId));
      this.ensureDirectory(this.registry.agentConversationDirOf(vaultId, session.id));
      return this.writeAtomic(key, json);
    });
    this.writeChains.set(key, job.then((): void => {
    }, (): void => {
    }));
    return job;
  }

  async remove(vaultId: string, conversationId: string): Promise<void> {
    const dir: string = this.registry.agentConversationDirOf(vaultId, conversationId);
    const pending: Promise<void> | undefined = this.writeChains.get(
      this.registry.agentConversationFileOf(vaultId, conversationId));
    if (pending !== undefined) {
      await pending;
    }
    if (fileIo.accessSync(dir)) {
      this.removeTree(dir);
    }
  }

  async removeVaultData(vaultId: string): Promise<void> {
    const conversationsDir: string = this.registry.agentConversationsDirOf(vaultId);
    const prefix: string = conversationsDir + '/';
    const pendingWrites: Promise<void>[] = [];
    this.writeChains.forEach((pending: Promise<void>, path: string): void => {
      if (path.startsWith(prefix)) {
        pendingWrites.push(pending);
      }
    });
    await Promise.all(pendingWrites);
    const dir: string = this.registry.agentVaultDirOf(vaultId);
    if (fileIo.accessSync(dir)) {
      this.removeTree(dir);
    }
  }

  static decode(raw: string, vaultKey: string, currentVaultId: string,
    conversationId: string): AgentSession | null {
    try {
      const document = JSON.parse(raw) as AgentConversationRaw;
      if (typeof document !== 'object' || document === null || typeof document.schemaVersion !== 'number' ||
        document.schemaVersion !== 1 || typeof document.vaultKey !== 'string' || document.vaultKey !== vaultKey ||
        typeof document.session !== 'object' || document.session === null) {
        return null;
      }
      const value = document.session as AgentSessionRaw;
      if (typeof value.id !== 'string' || value.id !== conversationId || typeof value.vaultId !== 'string' ||
        typeof value.title !== 'string' ||
        typeof value.skillId !== 'string' || typeof value.draft !== 'string' || !Array.isArray(value.messages)) {
        return null;
      }
      const session = document.session as AgentSession;
      const previousVaultId: string = value.vaultId;
      session.vaultId = currentVaultId;
      if (typeof value.titleManuallySet !== 'boolean') {
        session.titleManuallySet = false;
      }
      if (typeof value.archived !== 'boolean') {
        session.archived = false;
      }
      if (typeof value.updatedAt !== 'number') {
        session.updatedAt = 0;
      }
      if (previousVaultId !== currentVaultId) {
        AgentConversationStorage.updateOwner(session.messages, previousVaultId, currentVaultId);
      }
      return session;
    } catch (error) {
      return null;
    }
  }

  static encode(session: AgentSession, vaultKey: string): string {
    const document: AgentConversationDocument = { schemaVersion: 1, vaultKey: vaultKey, session: session };
    return JSON.stringify(document);
  }

  private static updateOwner(messages: AgentMessage[], oldVaultId: string, newVaultId: string): void {
    for (let i = 0; i < messages.length; i++) {
      const message: AgentMessage = messages[i];
      for (let j = 0; j < message.parts.length; j++) {
        if (message.parts[j].vaultId === oldVaultId) {
          message.parts[j].vaultId = newVaultId;
        }
      }
      for (let j = 0; j < message.references.length; j++) {
        if (message.references[j].vaultId === oldVaultId) {
          message.references[j].vaultId = newVaultId;
        }
      }
      if (message.writeResult !== null && message.writeResult.vaultId === oldVaultId) {
        message.writeResult.vaultId = newVaultId;
      }
    }
  }

  private ensureDirectory(path: string): void {
    if (fileIo.accessSync(path)) {
      return;
    }
    const slash: number = path.lastIndexOf('/');
    if (slash <= 0) {
      throw new Error('Agent 存储目录无效。');
    }
    const parent: string = path.substring(0, slash);
    if (!fileIo.accessSync(parent)) {
      this.ensureDirectory(parent);
    }
    fileIo.mkdirSync(path);
  }

  private writeAtomic(path: string, content: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(path);
      let settled: boolean = false;
      let timerId: number = -1;
      const fail = (message: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (error) {
          // Keep the original write error.
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
        } catch (error) {
          const err = error as BusinessError;
          fail(err.message);
          return;
        }
        settled = true;
        resolve();
      };
      try {
        const stream: fileIo.WriteStream = atomicFile.startWrite();
        timerId = setTimeout((): void => { fail('Agent 对话 AtomicFile 写入回调超时'); }, 3000);
        if (content.length === 0) {
          finish();
        } else {
          stream.write(content, 'utf-8', (err?: BusinessError): void => {
            if (err !== undefined && err !== null) {
              fail(err.message);
              return;
            }
            finish();
          });
        }
      } catch (error) {
        const err = error as BusinessError;
        fail(err.message);
      }
    });
  }

  private removeTree(path: string): void {
    const stat: fileIo.Stat = fileIo.statSync(path);
    if (!stat.isDirectory()) {
      fileIo.unlinkSync(path);
      return;
    }
    const names: string[] = fileIo.listFileSync(path);
    for (let i = 0; i < names.length; i++) {
      this.removeTree(path + '/' + names[i]);
    }
    fileIo.rmdirSync(path);
  }
}
