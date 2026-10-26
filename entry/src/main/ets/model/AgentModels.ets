export type AgentRole = 'user' | 'assistant';

export interface AgentToolStep {
  name: string;
  query?: string;
  path?: string;
  text?: string;
  anchor?: string;
}

export interface AgentScenario {
  id: string;
  inputs: string[];
  reply: string;
  tools: AgentToolStep[];
}

export interface AgentSkillDefault {
  id: string;
  name: string;
  revision: number;
  prompt: string;
  allowedTools: string[];
}

export interface AgentMessagePart {
  kind: 'text' | 'note_ref';
  text: string;
  path: string;
  vaultId: string;
}

export interface AgentNoteSnapshot {
  vaultId: string;
  path: string;
  content: string;
  contentHash: string;
}

export interface AgentToolEvent {
  name: string;
  status: 'completed' | 'failed';
  result: string;
  errorCode: string;
  operationId: string;
}

export interface AgentWriteResult {
  operationId: string;
  vaultId: string;
  path: string;
  before: string;
  after: string;
  created: boolean;
  undone: boolean;
}

export interface AgentMessage {
  id: string;
  role: AgentRole;
  parts: AgentMessagePart[];
  references: AgentNoteSnapshot[];
  toolEvents: AgentToolEvent[];
  writeResult: AgentWriteResult | null;
  configRevision: number;
  skillId: string;
  createdAt: number;
}

export interface AgentSession {
  id: string;
  vaultId: string;
  title: string;
  titleManuallySet?: boolean;
  archived?: boolean;
  skillId: string;
  draft: string;
  messages: AgentMessage[];
}

export interface AgentRunConfig {
  revision: number;
  systemPrompt: string;
  promptRevision: string;
  skillId: string;
  skillPrompt: string;
  enabledTools: string[];
  allowedTools: string[];
}

export interface AgentSettingsSnapshot {
  revision: number;
  systemPrompt: string;
  promptRevision: string;
  skillPrompts: Map<string, string>;
  enabledTools: Map<string, boolean>;
}
