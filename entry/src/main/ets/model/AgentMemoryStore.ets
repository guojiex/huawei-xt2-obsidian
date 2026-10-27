import { hilog } from '@kit.PerformanceAnalysisKit';
import { AgentMessage, AgentSession } from './AgentModels';
import { BUILTIN_AGENT_SKILLS } from './AgentDefaults';
import { AgentConversationStorage } from './AgentConversationStorage';
import { AgentRuntime } from './AgentRuntime';
import { VaultRegistry } from './VaultRegistry';

const AGENT_DOMAIN: number = 0x0000;
const AGENT_TAG: string = 'AgentMemoryStore';

export class AgentMemoryStore {
  private static sessionsByVault: Map<string, AgentSession[]> = new Map<string, AgentSession[]>();
  private static activeByVault: Map<string, string> = new Map<string, string>();
  private static panelStateByVault: Map<string, string> = new Map<string, string>();
  private static loadedVaults: Map<string, boolean> = new Map<string, boolean>();
  private static writeTimers: Map<string, number> = new Map<string, number>();
  private static storage: AgentConversationStorage | null = null;
  private static registry: VaultRegistry | null = null;
  private static serial: number = 0;

  static initialize(registry: VaultRegistry): void {
    if (AgentMemoryStore.storage !== null) {
      return;
    }
    AgentMemoryStore.registry = registry;
    AgentMemoryStore.storage = new AgentConversationStorage(registry);
  }

  static list(vaultId: string): AgentSession[] {
    AgentMemoryStore.ensureLoaded(vaultId);
    const key: string = AgentMemoryStore.keyFor(vaultId);
    const sessions: AgentSession[] | undefined = AgentMemoryStore.sessionsByVault.get(key);
    const list: AgentSession[] = sessions === undefined ? [] : sessions;
    AgentMemoryStore.updateCurrentOwner(list, vaultId);
    return list;
  }

  static get(vaultId: string, sessionId: string): AgentSession | null {
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId);
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId) {
        return sessions[i];
      }
    }
    return null;
  }

  static active(vaultId: string): AgentSession {
    const key: string = AgentMemoryStore.keyFor(vaultId);
    let activeId: string | undefined = AgentMemoryStore.activeByVault.get(key);
    let session: AgentSession | null = activeId === undefined ? null : AgentMemoryStore.get(vaultId, activeId);
    if (session === null || session.archived === true) {
      const recent: AgentSession[] = AgentMemoryStore.recent(vaultId);
      session = recent.length > 0 ? recent[0] : null;
    }
    if (session === null) {
      session = AgentMemoryStore.create(vaultId);
    }
    AgentMemoryStore.activeByVault.set(key, session.id);
    return session;
  }

  static recent(vaultId: string): AgentSession[] {
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId);
    const recent: AgentSession[] = [];
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].archived !== true) {
        recent.push(sessions[i]);
      }
    }
    return recent;
  }

  static create(vaultId: string): AgentSession {
    AgentMemoryStore.serial++;
    const session: AgentSession = {
      id: 'agent-' + Date.now().toString() + '-' + AgentMemoryStore.serial.toString(),
      vaultId,
      title: '新对话',
      titleManuallySet: false,
      archived: false,
      skillId: BUILTIN_AGENT_SKILLS.length > 0 ? BUILTIN_AGENT_SKILLS[0].id : 'reading',
      draft: '',
      messages: [],
      updatedAt: Date.now()
    };
    const key: string = AgentMemoryStore.keyFor(vaultId);
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId).slice();
    sessions.unshift(session);
    AgentMemoryStore.sessionsByVault.set(key, sessions);
    AgentMemoryStore.activeByVault.set(key, session.id);
    void AgentMemoryStore.persist(vaultId, session).catch((): void => {
      hilog.error(AGENT_DOMAIN, AGENT_TAG, '创建 Agent 对话保存失败；内存内容仍保留');
    });
    return session;
  }

  static activate(vaultId: string, sessionId: string): AgentSession | null {
    const key: string = AgentMemoryStore.keyFor(vaultId);
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session !== null && session.archived !== true) {
      AgentMemoryStore.activeByVault.set(key, sessionId);
      return session;
    }
    return null;
  }

  static async rename(vaultId: string, sessionId: string, title: string): Promise<boolean> {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    const cleaned: string = title.trim();
    if (session === null || cleaned.length === 0) {
      return false;
    }
    const previousTitle: string = session.title;
    const previousManual: boolean | undefined = session.titleManuallySet;
    session.title = cleaned;
    session.titleManuallySet = true;
    try {
      await AgentMemoryStore.persist(vaultId, session);
    } catch (error) {
      session.title = previousTitle;
      session.titleManuallySet = previousManual;
      const err = error as Error;
      throw new Error(err.message);
    }
    return true;
  }

  static async archive(vaultId: string, sessionId: string): Promise<boolean> {
    const key: string = AgentMemoryStore.keyFor(vaultId);
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null || session.archived === true) {
      return false;
    }
    session.archived = true;
    try {
      await AgentMemoryStore.persist(vaultId, session);
    } catch (error) {
      session.archived = false;
      const err = error as Error;
      throw new Error(err.message);
    }
    if (AgentMemoryStore.activeByVault.get(key) === sessionId) {
      AgentMemoryStore.activeByVault.delete(key);
      AgentMemoryStore.active(vaultId);
    }
    return true;
  }

  static async restore(vaultId: string, sessionId: string): Promise<boolean> {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null || session.archived !== true) {
      return false;
    }
    session.archived = false;
    try {
      await AgentMemoryStore.persist(vaultId, session);
    } catch (error) {
      session.archived = true;
      const err = error as Error;
      throw new Error(err.message);
    }
    return true;
  }

  static async remove(vaultId: string, sessionId: string): Promise<boolean> {
    const key: string = AgentMemoryStore.keyFor(vaultId);
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null) {
      return false;
    }
    const timerKey: string = AgentMemoryStore.timerKey(vaultId, sessionId);
    const timerId: number | undefined = AgentMemoryStore.writeTimers.get(timerKey);
    if (timerId !== undefined) {
      clearTimeout(timerId);
      AgentMemoryStore.writeTimers.delete(timerKey);
    }
    const storage: AgentConversationStorage | null = AgentMemoryStore.storage;
    if (storage !== null && AgentMemoryStore.hasPersistentVault(vaultId)) {
      await storage.remove(vaultId, sessionId);
    }
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId).slice();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId) {
        sessions.splice(i, 1);
        break;
      }
    }
    AgentMemoryStore.sessionsByVault.set(key, sessions);
    if (sessions.length === 0 || AgentMemoryStore.activeByVault.get(key) === sessionId) {
      AgentMemoryStore.activeByVault.delete(key);
      AgentMemoryStore.active(vaultId);
    }
    return true;
  }

  static append(vaultId: string, sessionId: string, message: AgentMessage): void {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null) {
      throw new Error('对话已失效，请重新选择。');
    }
    session.messages.push(message);
    AgentMemoryStore.schedulePersist(vaultId, session);
  }

  static setDraft(vaultId: string, sessionId: string, draft: string): void {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null) {
      return;
    }
    session.draft = draft;
    AgentMemoryStore.schedulePersist(vaultId, session);
  }

  static setSkill(vaultId: string, sessionId: string, skillId: string): void {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null) {
      return;
    }
    session.skillId = skillId;
    AgentMemoryStore.schedulePersist(vaultId, session);
  }

  static async persist(vaultId: string, session: AgentSession): Promise<void> {
    if (AgentRuntime.isVaultDeleting(vaultId)) {
      return;
    }
    const timerKey: string = AgentMemoryStore.timerKey(vaultId, session.id);
    const timerId: number | undefined = AgentMemoryStore.writeTimers.get(timerKey);
    if (timerId !== undefined) {
      clearTimeout(timerId);
      AgentMemoryStore.writeTimers.delete(timerKey);
    }
    const storage: AgentConversationStorage | null = AgentMemoryStore.storage;
    if (storage === null || !AgentMemoryStore.hasPersistentVault(vaultId)) {
      return;
    }
    await storage.save(vaultId, session);
  }

  static async flushPending(): Promise<void> {
    const registry: VaultRegistry | null = AgentMemoryStore.registry;
    if (registry === null) {
      return;
    }
    const vaults = registry.list();
    for (let i = 0; i < vaults.length; i++) {
      const key: string = AgentMemoryStore.keyFor(vaults[i].id);
      const sessions: AgentSession[] | undefined = AgentMemoryStore.sessionsByVault.get(key);
      if (sessions === undefined) {
        continue;
      }
      for (let j = 0; j < sessions.length; j++) {
        await AgentMemoryStore.persist(vaults[i].id, sessions[j]);
      }
    }
  }

  static async flushVault(vaultId: string): Promise<void> {
    const sessions: AgentSession[] | undefined = AgentMemoryStore.sessionsByVault.get(AgentMemoryStore.keyFor(vaultId));
    if (sessions === undefined) {
      return;
    }
    for (let i = 0; i < sessions.length; i++) {
      await AgentMemoryStore.persist(vaultId, sessions[i]);
    }
  }

  static async removeVaultData(vaultId: string): Promise<void> {
    const key: string = AgentMemoryStore.keyFor(vaultId);
    const prefix: string = key + ':';
    const timersToClear: string[] = [];
    AgentMemoryStore.writeTimers.forEach((timerId: number, timerKey: string): void => {
      if (timerKey.startsWith(prefix)) {
        clearTimeout(timerId);
        timersToClear.push(timerKey);
      }
    });
    for (let i = 0; i < timersToClear.length; i++) {
      AgentMemoryStore.writeTimers.delete(timersToClear[i]);
    }
    const storage: AgentConversationStorage | null = AgentMemoryStore.storage;
    if (storage !== null && AgentMemoryStore.hasPersistentVault(vaultId)) {
      await storage.removeVaultData(vaultId);
    }
    AgentMemoryStore.sessionsByVault.delete(key);
    AgentMemoryStore.activeByVault.delete(key);
    AgentMemoryStore.panelStateByVault.delete(key);
    AgentMemoryStore.loadedVaults.delete(key);
  }

  static setPanelState(vaultId: string, panelState: string): void {
    AgentMemoryStore.panelStateByVault.set(AgentMemoryStore.keyFor(vaultId), panelState);
  }

  static panelState(vaultId: string): string {
    const state: string | undefined = AgentMemoryStore.panelStateByVault.get(AgentMemoryStore.keyFor(vaultId));
    return state === undefined ? 'both' : state;
  }

  private static ensureLoaded(vaultId: string): void {
    const key: string = AgentMemoryStore.keyFor(vaultId);
    if (AgentMemoryStore.loadedVaults.has(key)) {
      return;
    }
    AgentMemoryStore.loadedVaults.set(key, true);
    const storage: AgentConversationStorage | null = AgentMemoryStore.storage;
    if (storage === null || !AgentMemoryStore.hasPersistentVault(vaultId)) {
      return;
    }
    try {
      AgentMemoryStore.sessionsByVault.set(key, storage.load(vaultId));
    } catch (error) {
      AgentMemoryStore.loadedVaults.delete(key);
      hilog.error(AGENT_DOMAIN, AGENT_TAG, '载入 Agent 对话失败，保留原文件供恢复');
    }
  }

  private static keyFor(vaultId: string): string {
    if (AgentMemoryStore.registry !== null) {
      try {
        return AgentMemoryStore.registry.vaultKeyOf(vaultId);
      } catch (error) {
        // Isolated model tests use synthetic vault IDs without a registry entry.
      }
    }
    return vaultId;
  }

  private static updateCurrentOwner(sessions: AgentSession[], vaultId: string): void {
    for (let i = 0; i < sessions.length; i++) {
      const session: AgentSession = sessions[i];
      if (session.vaultId === vaultId) {
        continue;
      }
      const previousVaultId: string = session.vaultId;
      session.vaultId = vaultId;
      for (let j = 0; j < session.messages.length; j++) {
        const message: AgentMessage = session.messages[j];
        for (let k = 0; k < message.parts.length; k++) {
          if (message.parts[k].vaultId === previousVaultId) {
            message.parts[k].vaultId = vaultId;
          }
        }
        for (let k = 0; k < message.references.length; k++) {
          if (message.references[k].vaultId === previousVaultId) {
            message.references[k].vaultId = vaultId;
          }
        }
        if (message.writeResult !== null && message.writeResult.vaultId === previousVaultId) {
          message.writeResult.vaultId = vaultId;
        }
      }
      AgentMemoryStore.schedulePersist(vaultId, session);
    }
  }

  private static schedulePersist(vaultId: string, session: AgentSession): void {
    if (AgentMemoryStore.storage === null || AgentMemoryStore.registry === null ||
      AgentRuntime.isVaultDeleting(vaultId)) {
      return;
    }
    const key: string = AgentMemoryStore.timerKey(vaultId, session.id);
    const existing: number | undefined = AgentMemoryStore.writeTimers.get(key);
    if (existing !== undefined) {
      clearTimeout(existing);
    }
    const timerId: number = setTimeout((): void => {
      AgentMemoryStore.writeTimers.delete(key);
      void AgentMemoryStore.persist(vaultId, session).catch((): void => {
        hilog.error(AGENT_DOMAIN, AGENT_TAG, '保存 Agent 对话失败；内存内容仍保留');
      });
    }, 400);
    AgentMemoryStore.writeTimers.set(key, timerId);
  }

  private static timerKey(vaultId: string, sessionId: string): string {
    return AgentMemoryStore.keyFor(vaultId) + ':' + sessionId;
  }

  private static hasPersistentVault(vaultId: string): boolean {
    if (AgentMemoryStore.storage === null || AgentMemoryStore.registry === null) {
      return false;
    }
    try {
      AgentMemoryStore.registry.vaultKeyOf(vaultId);
      return true;
    } catch (error) {
      return false;
    }
  }
}
