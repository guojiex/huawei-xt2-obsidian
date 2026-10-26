import { AgentMessage, AgentSession } from './AgentModels';
import { BUILTIN_AGENT_SKILLS } from './AgentDefaults';

export class AgentMemoryStore {
  private static sessionsByVault: Map<string, AgentSession[]> = new Map<string, AgentSession[]>();
  private static activeByVault: Map<string, string> = new Map<string, string>();
  private static panelStateByVault: Map<string, string> = new Map<string, string>();
  private static serial: number = 0;

  static list(vaultId: string): AgentSession[] {
    const sessions: AgentSession[] | undefined = AgentMemoryStore.sessionsByVault.get(vaultId);
    if (sessions === undefined) {
      return [];
    }
    return sessions;
  }

  static get(vaultId: string, sessionId: string): AgentSession | null {
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId);
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId && sessions[i].vaultId === vaultId) {
        return sessions[i];
      }
    }
    return null;
  }

  static active(vaultId: string): AgentSession {
    let activeId: string | undefined = AgentMemoryStore.activeByVault.get(vaultId);
    let session: AgentSession | null = activeId === undefined ? null : AgentMemoryStore.get(vaultId, activeId);
    if (session === null || session.archived === true) {
      const recent: AgentSession[] = AgentMemoryStore.recent(vaultId);
      session = recent.length > 0 ? recent[0] : null;
    }
    if (session === null) {
      session = AgentMemoryStore.create(vaultId);
    }
    AgentMemoryStore.activeByVault.set(vaultId, session.id);
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
      messages: []
    };
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId).slice();
    sessions.unshift(session);
    AgentMemoryStore.sessionsByVault.set(vaultId, sessions);
    AgentMemoryStore.activeByVault.set(vaultId, session.id);
    return session;
  }

  static activate(vaultId: string, sessionId: string): AgentSession | null {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session !== null && session.archived !== true) {
      AgentMemoryStore.activeByVault.set(vaultId, sessionId);
      return session;
    }
    return null;
  }

  static rename(vaultId: string, sessionId: string, title: string): boolean {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    const cleaned: string = title.trim();
    if (session === null || cleaned.length === 0) {
      return false;
    }
    session.title = cleaned;
    session.titleManuallySet = true;
    return true;
  }

  static archive(vaultId: string, sessionId: string): boolean {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null || session.archived === true) {
      return false;
    }
    session.archived = true;
    if (AgentMemoryStore.activeByVault.get(vaultId) === sessionId) {
      AgentMemoryStore.activeByVault.delete(vaultId);
      AgentMemoryStore.active(vaultId);
    }
    return true;
  }

  static restore(vaultId: string, sessionId: string): boolean {
    const session: AgentSession | null = AgentMemoryStore.get(vaultId, sessionId);
    if (session === null || session.archived !== true) {
      return false;
    }
    session.archived = false;
    return true;
  }

  static remove(vaultId: string, sessionId: string): boolean {
    const sessions: AgentSession[] = AgentMemoryStore.list(vaultId).slice();
    let index: number = -1;
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return false;
    }
    sessions.splice(index, 1);
    AgentMemoryStore.sessionsByVault.set(vaultId, sessions);
    if (sessions.length === 0 || AgentMemoryStore.activeByVault.get(vaultId) === sessionId) {
      AgentMemoryStore.activeByVault.delete(vaultId);
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
  }

  static setPanelState(vaultId: string, panelState: string): void {
    AgentMemoryStore.panelStateByVault.set(vaultId, panelState);
  }

  static panelState(vaultId: string): string {
    const state: string | undefined = AgentMemoryStore.panelStateByVault.get(vaultId);
    return state === undefined ? 'both' : state;
  }
}
