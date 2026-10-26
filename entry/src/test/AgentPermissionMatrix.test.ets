import { ArgumentMatchers, afterAll, beforeAll, beforeEach, describe, expect, it, MockKit, when } from '@ohos/hypium';
import { AgentMessage, AgentNoteSnapshot, AgentRunConfig, AgentSession } from '../main/ets/model/AgentModels';
import { AgentRules } from '../main/ets/model/AgentRules';
import { AgentRuntime } from '../main/ets/model/AgentRuntime';
import { NoteService } from '../main/ets/model/NoteService';
import { VaultRegistry } from '../main/ets/model/VaultRegistry';

const ALL_TOOLS: string[] = ['QueryNotes', 'ReadNote', 'CreateNote', 'AppendNote', 'EditNote', 'UndoLastEdit'];
type PermissionDenialMode = 'user' | 'skill' | 'both';
const TEST_REGISTRY: VaultRegistry = new Object() as Object as VaultRegistry;
let files: Map<string, string> = new Map<string, string>();
let mock: MockKit;
let fixtureSerial: number = 0;

function makeConfig(enabled: string[], allowed: string[]): AgentRunConfig {
  return {
    revision: 1,
    systemPrompt: '测试提示词',
    promptRevision: 'test',
    skillId: 'reading',
    skillPrompt: '测试 Skill',
    enabledTools: enabled.slice(),
    allowedTools: allowed.slice()
  };
}

function makeSession(vaultId: string): AgentSession {
  fixtureSerial++;
  return {
    id: 'agent-permission-test-' + fixtureSerial.toString(),
    vaultId,
    title: '新对话',
    skillId: 'reading',
    draft: '',
    messages: []
  };
}

function withoutTool(tools: string[], deniedTool: string): string[] {
  const result: string[] = [];
  for (let i = 0; i < tools.length; i++) {
    if (tools[i] !== deniedTool) {
      result.push(tools[i]);
    }
  }
  return result;
}

function snapshotFiles(): string {
  const entries: string[] = [];
  files.forEach((content: string, path: string): void => {
    entries.push(path + '\n' + content);
  });
  entries.sort();
  return entries.join('\n---\n');
}

function makeMocks(): void {
  mock = new MockKit();
  const existsMock: Function = mock.mockPrivateFunc(NoteService as Object, 'exists');
  when(existsMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
    .afterAction((_registry: Object, _vaultId: string, path: string): boolean => files.has(path));

  const readMock: Function = mock.mockPrivateFunc(NoteService as Object, 'tryReadNote');
  when(readMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
    .afterAction((_registry: Object, _vaultId: string, path: string): string | null => {
      const value: string | undefined = files.get(path);
      return value === undefined ? null : value;
    });

  const saveMock: Function = mock.mockPrivateFunc(NoteService as Object, 'saveNote');
  when(saveMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
    .afterAction((_registry: Object, _vaultId: string, path: string, content: string): Promise<void> => {
      files.set(path, content);
      return Promise.resolve();
    });

  const createMock: Function = mock.mockPrivateFunc(NoteService as Object, 'createNote');
  when(createMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
    .afterAction((_registry: Object, _vaultId: string, path: string): string => {
      let actualPath: string = path;
      let suffix: number = 2;
      const dot: number = path.lastIndexOf('.');
      const stem: string = dot < 0 ? path : path.substring(0, dot);
      const extension: string = dot < 0 ? '' : path.substring(dot);
      while (files.has(actualPath)) {
        actualPath = stem + '-' + suffix.toString() + extension;
        suffix++;
      }
      files.set(actualPath, '');
      return actualPath;
    });

  const deleteMock: Function = mock.mockPrivateFunc(NoteService as Object, 'deletePath');
  when(deleteMock)(ArgumentMatchers.any, ArgumentMatchers.any, ArgumentMatchers.any)
    .afterAction((_registry: Object, _vaultId: string, path: string): Promise<void> => {
      files.delete(path);
      return Promise.resolve();
    });
}

async function run(vaultId: string, session: AgentSession, rawText: string,
  config: AgentRunConfig): Promise<AgentMessage> {
  const parts = AgentRules.parseParts(rawText, vaultId);
  const references: AgentNoteSnapshot[] = AgentRuntime.captureReferences(vaultId, parts, TEST_REGISTRY,
    (_path: string): boolean => false);
  return await AgentRuntime.run(vaultId, session, AgentRuntime.newRunId(), rawText, parts, references, config,
    TEST_REGISTRY, (_path: string): boolean => false);
}

async function assertDeniedWithoutWrites(tool: string, deniedBy: PermissionDenialMode): Promise<void> {
  const vaultId: string = 'vault-permission-' + fixtureSerial.toString() + '-' + tool;
  const session: AgentSession = makeSession(vaultId);
  let question: string = '';
  if (tool === 'QueryNotes') {
    question = '查找阅读笔记';
  } else if (tool === 'ReadNote') {
    files.set('A.md', '受保护的原文');
    question = '读取引用笔记 [[A.md]]';
  } else if (tool === 'CreateNote') {
    question = '新建读书小结';
  } else if (tool === 'AppendNote') {
    files.set('A.md', '受保护的原文');
    question = '把这轮结论追加到笔记 [[A.md]]';
  } else if (tool === 'EditNote') {
    files.set('A.md', '熟悉不等于理解');
    question = '把熟悉改成理解 [[A.md]]';
  } else {
    const created: AgentMessage = await run(vaultId, session, '新建读书小结', makeConfig(ALL_TOOLS, ALL_TOOLS));
    expect(created.toolEvents[0].status).assertEqual('completed');
    question = '撤销上次修改';
  }

  const before: string = snapshotFiles();
  const enabled: string[] = deniedBy === 'skill' ? ALL_TOOLS : withoutTool(ALL_TOOLS, tool);
  const allowed: string[] = deniedBy === 'user' ? ALL_TOOLS : withoutTool(ALL_TOOLS, tool);
  const assistant: AgentMessage = await run(vaultId, session, question, makeConfig(enabled, allowed));
  let deniedIndex: number = -1;
  for (let i = 0; i < assistant.toolEvents.length; i++) {
    if (assistant.toolEvents[i].name === tool) {
      deniedIndex = i;
      break;
    }
  }
  expect(deniedIndex >= 0).assertTrue();
  expect(assistant.toolEvents[deniedIndex].status).assertEqual('failed');
  expect(assistant.toolEvents[deniedIndex].errorCode).assertEqual('PERMISSION_DENIED');
  expect(deniedIndex).assertEqual(assistant.toolEvents.length - 1);
  expect(assistant.writeResult === null).assertTrue();
  expect(snapshotFiles()).assertEqual(before);
}

export default function agentPermissionMatrixTest() {
  describe('AgentPermissionMatrix', () => {
    beforeAll((): void => {
      makeMocks();
    });

    beforeEach((): void => {
      files = new Map<string, string>();
    });

    it('rejects all six tools when either the user switch or Skill allowlist denies them', 0,
      async (): Promise<void> => {
        for (let i = 0; i < ALL_TOOLS.length; i++) {
          await assertDeniedWithoutWrites(ALL_TOOLS[i], 'user');
          await assertDeniedWithoutWrites(ALL_TOOLS[i], 'skill');
          await assertDeniedWithoutWrites(ALL_TOOLS[i], 'both');
        }
      });

    afterAll((): void => {
      mock.ignoreMock(NoteService as Object, 'exists');
      mock.ignoreMock(NoteService as Object, 'tryReadNote');
      mock.ignoreMock(NoteService as Object, 'saveNote');
      mock.ignoreMock(NoteService as Object, 'createNote');
      mock.ignoreMock(NoteService as Object, 'deletePath');
    });
  });
}
