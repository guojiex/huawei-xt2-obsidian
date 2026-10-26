import { AgentRunConfig, AgentSettingsSnapshot } from './AgentModels';
import { AGENT_TOOL_NAMES } from './AgentRules';
import { BUILTIN_AGENT_PROMPT, BUILTIN_AGENT_PROMPT_REVISION, BUILTIN_AGENT_SKILLS } from './AgentDefaults';

export class AgentConfigStore {
  private static revision: number = 0;
  private static systemPrompt: string = BUILTIN_AGENT_PROMPT;
  private static promptRevision: string = BUILTIN_AGENT_PROMPT_REVISION;
  private static skillPrompts: Map<string, string> = new Map<string, string>();
  private static enabledTools: Map<string, boolean> = new Map<string, boolean>();

  private static ensure(): void {
    for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
      const skill: string = BUILTIN_AGENT_SKILLS[i].id;
      if (!AgentConfigStore.skillPrompts.has(skill)) {
        AgentConfigStore.skillPrompts.set(skill, BUILTIN_AGENT_SKILLS[i].prompt);
      }
    }
    for (let i = 0; i < AGENT_TOOL_NAMES.length; i++) {
      const name: string = AGENT_TOOL_NAMES[i];
      if (!AgentConfigStore.enabledTools.has(name)) {
        AgentConfigStore.enabledTools.set(name, true);
      }
    }
  }

  static snapshot(skillId: string): AgentRunConfig {
    AgentConfigStore.ensure();
    let skillPrompt: string = '';
    let allowedTools: string[] = [];
    for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
      if (BUILTIN_AGENT_SKILLS[i].id === skillId) {
        skillPrompt = AgentConfigStore.skillPrompts.get(skillId) ?? BUILTIN_AGENT_SKILLS[i].prompt;
        allowedTools = BUILTIN_AGENT_SKILLS[i].allowedTools.slice();
        break;
      }
    }
    const enabledTools: string[] = [];
    for (let i = 0; i < AGENT_TOOL_NAMES.length; i++) {
      const name: string = AGENT_TOOL_NAMES[i];
      if (AgentConfigStore.enabledTools.get(name) === true) {
        enabledTools.push(name);
      }
    }
    return {
      revision: AgentConfigStore.revision,
      systemPrompt: AgentConfigStore.systemPrompt,
      promptRevision: AgentConfigStore.promptRevision,
      skillId,
      skillPrompt,
      enabledTools,
      allowedTools
    };
  }

  static currentSettings(): AgentSettingsSnapshot {
    AgentConfigStore.ensure();
    return {
      revision: AgentConfigStore.revision,
      systemPrompt: AgentConfigStore.systemPrompt,
      promptRevision: AgentConfigStore.promptRevision,
      skillPrompts: new Map<string, string>(AgentConfigStore.skillPrompts),
      enabledTools: new Map<string, boolean>(AgentConfigStore.enabledTools)
    };
  }

  static saveSystemPrompt(prompt: string): void {
    if (prompt.trim().length === 0) {
      throw new Error('系统提示词不能为空；如需恢复默认，请使用“恢复内置默认”。');
    }
    AgentConfigStore.systemPrompt = prompt;
    AgentConfigStore.promptRevision = 'custom:' + (AgentConfigStore.revision + 1).toString();
    AgentConfigStore.revision++;
  }

  static restoreSystemPrompt(): void {
    AgentConfigStore.systemPrompt = BUILTIN_AGENT_PROMPT;
    AgentConfigStore.promptRevision = BUILTIN_AGENT_PROMPT_REVISION;
    AgentConfigStore.revision++;
  }

  static saveSkillPrompt(skillId: string, prompt: string): void {
    if (prompt.trim().length === 0) {
      throw new Error('Skill 提示词不能为空。');
    }
    if (AgentConfigStore.defaultSkill(skillId) === null) {
      throw new Error('内置 Skill 不存在。');
    }
    AgentConfigStore.skillPrompts.set(skillId, prompt);
    AgentConfigStore.revision++;
  }

  static restoreSkillPrompt(skillId: string): void {
    const skill = AgentConfigStore.defaultSkill(skillId);
    if (skill === null) {
      throw new Error('内置 Skill 不存在。');
    }
    AgentConfigStore.skillPrompts.set(skillId, skill.prompt);
    AgentConfigStore.revision++;
  }

  static setToolEnabled(name: string, enabled: boolean): void {
    if (AGENT_TOOL_NAMES.indexOf(name) < 0) {
      throw new Error('不能启用未知工具。');
    }
    AgentConfigStore.enabledTools.set(name, enabled);
    AgentConfigStore.revision++;
  }

  static skillDefaults() {
    return BUILTIN_AGENT_SKILLS;
  }

  static toolNames(): string[] {
    return AGENT_TOOL_NAMES.slice();
  }

  private static defaultSkill(skillId: string) {
    for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
      if (BUILTIN_AGENT_SKILLS[i].id === skillId) {
        return BUILTIN_AGENT_SKILLS[i];
      }
    }
    return null;
  }
}
