import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { AgentRunConfig, AgentSettingsSnapshot, AgentSkillDefault } from './AgentModels';
import { AGENT_TOOL_NAMES } from './AgentRules';
import { BUILTIN_AGENT_PROMPT, BUILTIN_AGENT_PROMPT_REVISION, BUILTIN_AGENT_SKILLS } from './AgentDefaults';

interface AgentSystemPromptValue {
  mode: string;
  baseRevision: string;
  customText: string;
}

export interface AgentSettingsDocument {
  schemaVersion: number;
  configRevision: number;
  systemPrompt: AgentSystemPromptValue;
  defaultSkillId: string;
  skillOverrides: Record<string, string>;
  enabledTools: string[];
}

interface AgentSettingsRaw {
  schemaVersion?: Object;
  configRevision?: Object;
  systemPrompt?: Object;
  defaultSkillId?: Object;
  skillOverrides?: Object;
  enabledTools?: Object;
}

interface AgentSystemPromptRaw {
  mode?: Object;
  baseRevision?: Object;
  customText?: Object;
}

export class AgentConfigStore {
  private static revision: number = 0;
  private static systemPrompt: string = BUILTIN_AGENT_PROMPT;
  private static promptRevision: string = BUILTIN_AGENT_PROMPT_REVISION;
  private static skillPrompts: Map<string, string> = new Map<string, string>();
  private static enabledTools: Map<string, boolean> = new Map<string, boolean>();
  private static store: preferences.Preferences | null = null;
  private static initialized: boolean = false;
  private static invalidStoredValue: boolean = false;
  private static storageUnavailable: boolean = false;
  private static readonly PREF_NAME: string = 'agent_settings';
  private static readonly PREF_KEY: string = 'settings_json';

  static initialize(context: common.UIAbilityContext): void {
    if (AgentConfigStore.initialized) {
      return;
    }
    AgentConfigStore.initialized = true;
    try {
      AgentConfigStore.store = preferences.getPreferencesSync(context, { name: AgentConfigStore.PREF_NAME });
      const raw: string = AgentConfigStore.store.getSync(AgentConfigStore.PREF_KEY, '') as string;
      if (raw.length > 0 && !AgentConfigStore.loadDocument(raw)) {
        AgentConfigStore.invalidStoredValue = true;
      }
    } catch (error) {
      AgentConfigStore.storageUnavailable = true;
    }
  }

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
    const before: AgentSettingsDocument = AgentConfigStore.document();
    AgentConfigStore.systemPrompt = prompt;
    AgentConfigStore.promptRevision = 'custom:' + (AgentConfigStore.revision + 1).toString();
    AgentConfigStore.revision++;
    AgentConfigStore.persistOrRestore(before);
  }

  static restoreSystemPrompt(): void {
    const before: AgentSettingsDocument = AgentConfigStore.document();
    AgentConfigStore.systemPrompt = BUILTIN_AGENT_PROMPT;
    AgentConfigStore.promptRevision = BUILTIN_AGENT_PROMPT_REVISION;
    AgentConfigStore.revision++;
    AgentConfigStore.persistOrRestore(before);
  }

  static saveSkillPrompt(skillId: string, prompt: string): void {
    if (prompt.trim().length === 0) {
      throw new Error('Skill 提示词不能为空。');
    }
    if (AgentConfigStore.defaultSkill(skillId) === null) {
      throw new Error('内置 Skill 不存在。');
    }
    AgentConfigStore.ensure();
    const before: AgentSettingsDocument = AgentConfigStore.document();
    AgentConfigStore.skillPrompts.set(skillId, prompt);
    AgentConfigStore.revision++;
    AgentConfigStore.persistOrRestore(before);
  }

  static restoreSkillPrompt(skillId: string): void {
    const skill = AgentConfigStore.defaultSkill(skillId);
    if (skill === null) {
      throw new Error('内置 Skill 不存在。');
    }
    AgentConfigStore.ensure();
    const before: AgentSettingsDocument = AgentConfigStore.document();
    AgentConfigStore.skillPrompts.set(skillId, skill.prompt);
    AgentConfigStore.revision++;
    AgentConfigStore.persistOrRestore(before);
  }

  static setToolEnabled(name: string, enabled: boolean): void {
    if (AGENT_TOOL_NAMES.indexOf(name) < 0) {
      throw new Error('不能启用未知工具。');
    }
    AgentConfigStore.ensure();
    const before: AgentSettingsDocument = AgentConfigStore.document();
    AgentConfigStore.enabledTools.set(name, enabled);
    AgentConfigStore.revision++;
    AgentConfigStore.persistOrRestore(before);
  }

  static skillDefaults(): AgentSkillDefault[] {
    return BUILTIN_AGENT_SKILLS;
  }

  static toolNames(): string[] {
    return AGENT_TOOL_NAMES.slice();
  }

  static decode(raw: string): AgentSettingsDocument | null {
    try {
      const value = JSON.parse(raw) as AgentSettingsRaw;
      if (typeof value !== 'object' || value === null || typeof value.schemaVersion !== 'number' ||
        value.schemaVersion !== 1 || typeof value.configRevision !== 'number' ||
        typeof value.systemPrompt !== 'object' || value.systemPrompt === null ||
        !Array.isArray(value.enabledTools)) {
        return null;
      }
      const prompt = value.systemPrompt as AgentSystemPromptRaw;
      if (typeof prompt.mode !== 'string' || typeof prompt.baseRevision !== 'string' ||
        typeof prompt.customText !== 'string' || (prompt.mode !== 'builtin' && prompt.mode !== 'custom') ||
        (prompt.mode === 'custom' && prompt.customText.trim().length === 0)) {
        return null;
      }
      const rawOverrides: Record<string, string> = typeof value.skillOverrides === 'object' &&
        value.skillOverrides !== null ? value.skillOverrides as Record<string, string> : {};
      const overrides: Record<string, string> = {};
      for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
        const id: string = BUILTIN_AGENT_SKILLS[i].id;
        const override = rawOverrides[id] as Object;
        if (typeof override === 'string' && override.length > 0) {
          overrides[id] = override;
        }
      }
      const enabledTools: string[] = [];
      for (let i = 0; i < value.enabledTools.length; i++) {
        if (typeof value.enabledTools[i] === 'string') {
          enabledTools.push(value.enabledTools[i] as string);
        }
      }
      return {
        schemaVersion: 1,
        configRevision: value.configRevision,
        systemPrompt: {
          mode: prompt.mode,
          baseRevision: prompt.baseRevision,
          customText: prompt.customText
        },
        defaultSkillId: typeof value.defaultSkillId === 'string' ? value.defaultSkillId : 'reading',
        skillOverrides: overrides,
        enabledTools: enabledTools
      };
    } catch (error) {
      return null;
    }
  }

  static encodeCurrent(): string {
    return JSON.stringify(AgentConfigStore.document());
  }

  private static loadDocument(raw: string): boolean {
    const document: AgentSettingsDocument | null = AgentConfigStore.decode(raw);
    if (document === null) {
      return false;
    }
    AgentConfigStore.skillPrompts = new Map<string, string>();
    AgentConfigStore.enabledTools = new Map<string, boolean>();
    AgentConfigStore.ensure();
    AgentConfigStore.revision = document.configRevision;
    if (document.systemPrompt.mode === 'custom') {
      AgentConfigStore.systemPrompt = document.systemPrompt.customText;
      AgentConfigStore.promptRevision = 'custom:' + document.configRevision.toString();
    } else {
      AgentConfigStore.systemPrompt = BUILTIN_AGENT_PROMPT;
      AgentConfigStore.promptRevision = BUILTIN_AGENT_PROMPT_REVISION;
    }
    for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
      const id: string = BUILTIN_AGENT_SKILLS[i].id;
      const override: string | undefined = document.skillOverrides[id];
      if (override !== undefined) {
        AgentConfigStore.skillPrompts.set(id, override);
      }
    }
    for (let i = 0; i < AGENT_TOOL_NAMES.length; i++) {
      AgentConfigStore.enabledTools.set(AGENT_TOOL_NAMES[i], document.enabledTools.indexOf(AGENT_TOOL_NAMES[i]) >= 0);
    }
    return true;
  }

  private static document(): AgentSettingsDocument {
    AgentConfigStore.ensure();
    const skillOverrides: Record<string, string> = {};
    for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
      const skill: AgentSkillDefault = BUILTIN_AGENT_SKILLS[i];
      const prompt: string = AgentConfigStore.skillPrompts.get(skill.id) ?? skill.prompt;
      if (prompt !== skill.prompt) {
        skillOverrides[skill.id] = prompt;
      }
    }
    const enabledTools: string[] = [];
    for (let i = 0; i < AGENT_TOOL_NAMES.length; i++) {
      if (AgentConfigStore.enabledTools.get(AGENT_TOOL_NAMES[i]) === true) {
        enabledTools.push(AGENT_TOOL_NAMES[i]);
      }
    }
    const isBuiltin: boolean = AgentConfigStore.promptRevision === BUILTIN_AGENT_PROMPT_REVISION;
    return {
      schemaVersion: 1,
      configRevision: AgentConfigStore.revision,
      systemPrompt: {
        mode: isBuiltin ? 'builtin' : 'custom',
        baseRevision: BUILTIN_AGENT_PROMPT_REVISION,
        customText: isBuiltin ? '' : AgentConfigStore.systemPrompt
      },
      defaultSkillId: 'reading',
      skillOverrides: skillOverrides,
      enabledTools: enabledTools
    };
  }

  private static persistOrRestore(previous: AgentSettingsDocument): void {
    try {
      AgentConfigStore.persist();
    } catch (error) {
      AgentConfigStore.loadDocument(JSON.stringify(previous));
      const err = error as Error;
      throw new Error(err.message);
    }
  }

  private static persist(): void {
    if (!AgentConfigStore.initialized) {
      return;
    }
    if (AgentConfigStore.invalidStoredValue) {
      throw new Error('Agent 设置文件格式异常，已保留原数据，暂不能覆盖。');
    }
    if (AgentConfigStore.storageUnavailable || AgentConfigStore.store === null) {
      throw new Error('Agent 设置暂不可保存，请稍后重试。');
    }
    try {
      AgentConfigStore.store.putSync(AgentConfigStore.PREF_KEY, AgentConfigStore.encodeCurrent());
      AgentConfigStore.store.flushSync();
    } catch (error) {
      const err = error as BusinessError;
      throw new Error(err.message);
    }
  }

  private static defaultSkill(skillId: string): AgentSkillDefault | null {
    for (let i = 0; i < BUILTIN_AGENT_SKILLS.length; i++) {
      if (BUILTIN_AGENT_SKILLS[i].id === skillId) {
        return BUILTIN_AGENT_SKILLS[i];
      }
    }
    return null;
  }
}
