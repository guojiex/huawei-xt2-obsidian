import { AgentMessagePart, AgentScenario, AgentToolStep } from './AgentModels';

export const AGENT_TOOL_NAMES: string[] = [
  'QueryNotes', 'ReadNote', 'CreateNote', 'AppendNote', 'EditNote', 'UndoLastEdit'
];

export class AgentRules {
  /** 以 [[库内相对路径]] 表示引用；数组顺序与重复位置均保留。 */
  static parseParts(text: string, vaultId: string): AgentMessagePart[] {
    const parts: AgentMessagePart[] = [];
    let cursor: number = 0;
    while (cursor < text.length) {
      const start: number = text.indexOf('[[', cursor);
      if (start < 0) {
        if (cursor < text.length) {
          parts.push({ kind: 'text', text: text.substring(cursor), path: '', vaultId: '' });
        }
        break;
      }
      if (start > cursor) {
        parts.push({ kind: 'text', text: text.substring(cursor, start), path: '', vaultId: '' });
      }
      const end: number = text.indexOf(']]', start + 2);
      if (end < 0) {
        throw new Error('引用格式未闭合；请移除或重新选择笔记。');
      }
      const path: string = text.substring(start + 2, end);
      if (path.length === 0 || path.indexOf('\n') >= 0 || path.indexOf('\r') >= 0) {
        throw new Error('引用路径无效；请重新选择笔记。');
      }
      parts.push({ kind: 'note_ref', text: '', path, vaultId });
      cursor = end + 2;
    }
    if (text.length === 0) {
      parts.push({ kind: 'text', text: '', path: '', vaultId: '' });
    }
    return parts;
  }

  static insertReference(text: string, selectionStart: number, selectionEnd: number, path: string): string {
    const start: number = Math.max(0, Math.min(selectionStart, text.length));
    const end: number = Math.max(start, Math.min(selectionEnd, text.length));
    const marker: string = '[[' + path + ']]';
    return text.substring(0, start) + marker + text.substring(end);
  }

  static commandText(parts: AgentMessagePart[]): string {
    let text: string = '';
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].kind === 'text') {
        text += parts[i].text;
      }
    }
    return text.trim();
  }

  static scenarioFor(parts: AgentMessagePart[], scenarios: AgentScenario[]): AgentScenario | null {
    const command: string = AgentRules.commandText(parts);
    for (let i = 0; i < scenarios.length; i++) {
      if (scenarios[i].inputs.indexOf(command) >= 0) {
        return scenarios[i];
      }
    }
    return null;
  }

  static toolAllowed(name: string, enabledTools: string[], allowedTools: string[]): boolean {
    return AGENT_TOOL_NAMES.indexOf(name) >= 0 &&
      enabledTools.indexOf(name) >= 0 && allowedTools.indexOf(name) >= 0;
  }

  static validateStep(step: AgentToolStep): void {
    if (AGENT_TOOL_NAMES.indexOf(step.name) < 0) {
      throw new Error('UNKNOWN_TOOL：不支持的本地工具。');
    }
  }

  static uniqueAnchorRange(content: string, anchor: string): number[] {
    if (anchor.length === 0) {
      throw new Error('ANCHOR_NOT_UNIQUE：替换锚点不能为空。');
    }
    const start: number = content.indexOf(anchor);
    if (start < 0 || content.indexOf(anchor, start + anchor.length) >= 0) {
      throw new Error('ANCHOR_NOT_UNIQUE：原文不存在或出现多次，未写入。');
    }
    return [start, start + anchor.length];
  }
}
