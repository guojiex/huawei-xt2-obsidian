import { ArgumentMatchers, afterAll, beforeAll, beforeEach, describe, expect, it, MockKit, when } from '@ohos/hypium';
import { AgentConfigStore } from '../main/ets/model/AgentConfigStore';
import { AgentMessage, AgentNoteSnapshot, AgentRunConfig, AgentSession } from '../main/ets/model/AgentModels';
import { AgentRules } from '../main/ets/model/AgentRules';
import { AgentRuntime } from '../main/ets/model/AgentRuntime';
import { NoteService } from '../main/ets/model/NoteService';
import { VaultRegistry } from '../main/ets/model/VaultRegistry';

const ALL_TOOLS: string[] = ['QueryNotes', 'ReadNote', 'CreateNote', 'AppendNote', 'EditNote', 'UndoLastEdit'];
const TEST_REGISTRY: VaultRegistry = new Object() as Object as VaultRegistry;
let files: Map<string, string> = new Map<string, string>();
let mock: MockKit;
let fixtureSerial: number = 0;
let failNextSave: boolean = false;

function makeConfig(enabled: string[] = ALL_TOOLS, allowed: string[] = ALL_TOOLS): AgentRunConfig {
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
    id: 'agent-runtime-test-' + fixtureSerial.toString(),
    vaultId,
    title: '新对话',
    skillId: 'reading',
    draft: '',
    messages: []
  };
}

function capture(vaultId: string, rawText: string): AgentNoteSnapshot[] {
  const parts = AgentRules.parseParts(rawText, vaultId);
  return AgentRuntime.captureReferences(vaultId, parts, TEST_REGISTRY, (_path: string): boolean => false);
}

async function run(vaultId: string, session: AgentSession, rawText: string,
  config: AgentRunConfig = makeConfig(), runId: string = AgentRuntime.newRunId()): Promise<AgentMessage> {
  const parts = AgentRules.parseParts(rawText, vaultId);
  const references = AgentRuntime.captureReferences(vaultId, parts, TEST_REGISTRY,
    (_path: string): boolean => false);
  return await AgentRuntime.run(vaultId, session, runId, rawText, parts, references, config,
    TEST_REGISTRY, (_path: string): boolean => false);
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
      if (failNextSave) {
        failNextSave = false;
        return Promise.reject(new Error('模拟 AtomicFile 保存失败'));
      }
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

export default function agentRuntimeTest() {
  describe('AgentRuntime', () => {
    beforeAll((): void => {
      makeMocks();
    });

    beforeEach((): void => {
      files = new Map<string, string>();
      failNextSave = false;
    });

    it('returns the supported questions without running tools for unmatched input', 0,
      async (): Promise<void> => {
        const vaultId: string = 'vault-unknown-' + fixtureSerial.toString();
        const session: AgentSession = makeSession(vaultId);
        const assistant: AgentMessage = await run(vaultId, session, '这个输入不对应固定问法');
        expect(session.messages.length).assertEqual(2);
        expect(assistant.toolEvents.length).assertEqual(0);
        expect(assistant.parts.length).assertEqual(1);
        expect(assistant.parts[0].text).assertContain('没有匹配本地固定 mock 场景；不会调用工具。');
        expect(assistant.parts[0].text).assertContain('请追问我');
        expect(files.size).assertEqual(0);
      });

    it('keeps a vault when private-data cleanup fails and permits a later retry', 0,
      async (): Promise<void> => {
        let cleanupCalls: number = 0;
        let removeCalls: number = 0;
        let failed: boolean = false;
        try {
          await AgentRuntime.deleteVaultWithCleanup('vault-delete-test', async (): Promise<void> => {
            cleanupCalls++;
            throw new Error('模拟私有数据清理失败');
          }, (): void => {
            removeCalls++;
          });
        } catch (error) {
          failed = true;
        }
        expect(failed).assertTrue();
        expect(cleanupCalls).assertEqual(1);
        expect(removeCalls).assertEqual(0);

        const removed: boolean = await AgentRuntime.deleteVaultWithCleanup('vault-delete-test',
          async (): Promise<void> => {
            cleanupCalls++;
          }, (): void => {
            removeCalls++;
          });
        expect(removed).assertTrue();
        expect(cleanupCalls).assertEqual(2);
        expect(removeCalls).assertEqual(1);
      });

    afterAll((): void => {
      mock.ignoreMock(NoteService as Object, 'exists');
      mock.ignoreMock(NoteService as Object, 'tryReadNote');
      mock.ignoreMock(NoteService as Object, 'saveNote');
      mock.ignoreMock(NoteService as Object, 'createNote');
      mock.ignoreMock(NoteService as Object, 'deletePath');
      for (let i = 0; i < ALL_TOOLS.length; i++) {
        AgentConfigStore.setToolEnabled(ALL_TOOLS[i], true);
      }
      AgentConfigStore.restoreSystemPrompt();
    });

    it('preserves interleaved and repeated inline references in source order', 0, (): void => {
      const parts = AgentRules.parseParts('先读 [[A.md]]，再比较 [[B.md]]，最后回看 [[A.md]]。', 'vault-a');
      expect(parts.length).assertEqual(7);
      expect(parts[0].text).assertEqual('先读 ');
      expect(parts[1].path).assertEqual('A.md');
      expect(parts[2].text).assertEqual('，再比较 ');
      expect(parts[3].path).assertEqual('B.md');
      expect(parts[4].text).assertEqual('，最后回看 ');
      expect(parts[5].path).assertEqual('A.md');
      expect(parts[6].text).assertEqual('。');
      const repeated = AgentRules.parseParts('[[A.md]] [[A.md]]', 'vault-a');
      expect(repeated.length).assertEqual(3);
      expect(repeated[0].path).assertEqual('A.md');
      expect(repeated[2].path).assertEqual('A.md');
    });

    it('rejects out-of-vault and invalid paths before a tool can write', 0, (): void => {
      let crossVaultRejected: boolean = false;
      try {
        const parts = AgentRules.parseParts('[[A.md]]', 'vault-b');
        AgentRuntime.captureReferences('vault-a', parts, TEST_REGISTRY, (_path: string): boolean => false);
      } catch (error) {
        crossVaultRejected = true;
      }
      expect(crossVaultRejected).assertTrue();

      let traversalRejected: boolean = false;
      try {
        capture('vault-a', '[[../outside.md]]');
      } catch (error) {
        traversalRejected = true;
      }
      expect(traversalRejected).assertTrue();
      expect(files.size).assertEqual(0);
    });

    it('requires both the user tool switch and the Skill allowlist', 0, async (): Promise<void> => {
      const session: AgentSession = makeSession('vault-disabled-' + fixtureSerial.toString());
      const toolDisabled = await run(session.vaultId, session, '新建读书小结', makeConfig(
        ['QueryNotes', 'ReadNote', 'AppendNote', 'EditNote', 'UndoLastEdit'], ALL_TOOLS));
      expect(toolDisabled.toolEvents[0].status).assertEqual('failed');
      expect(toolDisabled.toolEvents[0].errorCode).assertEqual('PERMISSION_DENIED');
      expect(files.size).assertEqual(0);

      const skillRestricted = await run(session.vaultId, makeSession(session.vaultId), '新建读书小结',
        makeConfig(ALL_TOOLS, ['QueryNotes', 'ReadNote']));
      expect(skillRestricted.toolEvents[0].status).assertEqual('failed');
      expect(files.size).assertEqual(0);
    });

    it('executes a fixed create once and leaves no partial file after a failed atomic save', 0,
      async (): Promise<void> => {
        const vaultId: string = 'vault-create-' + fixtureSerial.toString();
        const session: AgentSession = makeSession(vaultId);
      const question: string = '新建读书小结';
      const runId: string = AgentRuntime.newRunId();
      const first = await run(vaultId, session, question, makeConfig(), runId);
        expect(first.toolEvents[0].status).assertEqual('completed');
        expect(files.size).assertEqual(1);
        const createdPath: string = first.writeResult?.path ?? '';
        expect(files.get(createdPath) ?? '').assertContain('# 读书小结');

      const replay = await run(vaultId, session, question, makeConfig(), runId);
      expect(replay.toolEvents[0].status).assertEqual('completed');
      expect(replay.id).assertEqual(first.id);
      expect(replay.toolEvents[0].operationId).assertEqual(first.toolEvents[0].operationId);
      expect(session.messages.length).assertEqual(2);
        expect(files.size).assertEqual(1);

      await run(vaultId, session, question);
      expect(files.size).assertEqual(2);

        files = new Map<string, string>();
        failNextSave = true;
        const failed = await run('vault-create-failure-' + fixtureSerial.toString(),
          makeSession('vault-create-failure-' + fixtureSerial.toString()), '新建读书小结');
        expect(failed.toolEvents[0].status).assertEqual('failed');
        expect(failed.writeResult === null).assertTrue();
        expect(files.size).assertEqual(0);
      });

    it('deduplicates a replay of one run but allows the same instruction in a new run', 0,
      async (): Promise<void> => {
      const vaultId: string = 'vault-append-' + fixtureSerial.toString();
      files.set('A.md', '原文');
      const session: AgentSession = makeSession(vaultId);
      const question: string = '把这轮结论追加到笔记 [[A.md]]';
      const runId: string = AgentRuntime.newRunId();
      const first = await run(vaultId, session, question, makeConfig(), runId);
      expect(first.toolEvents[0].name).assertEqual('ReadNote');
      expect(first.toolEvents[0].status).assertEqual('completed');
      expect(first.toolEvents[1].name).assertEqual('AppendNote');
      const once: string = '原文\n阅读后的自检：用自己的话解释，再举一个例子和一个反例。';
      expect(files.get('A.md') ?? '').assertEqual(once);

      const replay = await run(vaultId, session, question, makeConfig(), runId);
      expect(replay.toolEvents[1].status).assertEqual('completed');
      expect(replay.id).assertEqual(first.id);
      expect(replay.toolEvents[1].operationId).assertEqual(first.toolEvents[1].operationId);
      expect(session.messages.length).assertEqual(2);
      expect(files.get('A.md') ?? '').assertEqual(once);

      const nextTurn = await run(vaultId, session, question);
      expect(nextTurn.toolEvents[1].status).assertEqual('completed');
      expect(nextTurn.toolEvents[1].operationId === first.toolEvents[1].operationId).assertFalse();
      expect(files.get('A.md') ?? '').assertEqual(once + '\n阅读后的自检：用自己的话解释，再举一个例子和一个反例。');
    });

    it('blocks stale, unsaved, and ambiguous write targets without changing files', 0,
      async (): Promise<void> => {
        const vaultId: string = 'vault-conflicts-' + fixtureSerial.toString();
        files.set('A.md', '引用时内容');
        const session: AgentSession = makeSession(vaultId);
        const rawText: string = '把这轮结论追加到笔记 [[A.md]]';
        const parts = AgentRules.parseParts(rawText, vaultId);
        const references = AgentRuntime.captureReferences(vaultId, parts, TEST_REGISTRY,
          (_path: string): boolean => false);
        files.set('A.md', '外部更新');
        const stale = await AgentRuntime.run(vaultId, session, AgentRuntime.newRunId(), rawText, parts, references,
          makeConfig(), TEST_REGISTRY, (_path: string): boolean => false);
        expect(stale.toolEvents[0].status).assertEqual('failed');
        expect(files.get('A.md') ?? '').assertEqual('外部更新');

        let unsavedRejected: boolean = false;
        try {
          AgentRuntime.captureReferences(vaultId, parts, TEST_REGISTRY,
            (_path: string): boolean => true);
        } catch (error) {
          unsavedRejected = true;
        }
        expect(unsavedRejected).assertTrue();

        files.set('A.md', 'A');
        files.set('B.md', 'B');
        const multiple = await run(vaultId, makeSession(vaultId),
          '把这轮结论追加到笔记 [[A.md]] [[B.md]]');
        expect(multiple.toolEvents[1].status).assertEqual('failed');
        expect(multiple.toolEvents[1].errorCode).assertEqual('AMBIGUOUS_TARGET');
        expect(files.get('A.md') ?? '').assertEqual('A');
        expect(files.get('B.md') ?? '').assertEqual('B');
      });

    it('requires one unique edit anchor and refuses undo after a later change', 0,
      async (): Promise<void> => {
        const vaultId: string = 'vault-edit-' + fixtureSerial.toString();
        files.set('A.md', '熟悉不等于理解\n熟悉不等于理解');
        const session: AgentSession = makeSession(vaultId);
        const ambiguous = await run(vaultId, session, '把熟悉改成理解 [[A.md]]');
        expect(ambiguous.toolEvents[1].status).assertEqual('failed');
        expect(ambiguous.toolEvents[1].errorCode).assertEqual('ANCHOR_NOT_UNIQUE');
        expect(files.get('A.md') ?? '').assertEqual('熟悉不等于理解\n熟悉不等于理解');

        files.set('A.md', '熟悉不等于理解');
        const edited = await run(vaultId, session, '把熟悉改成理解 [[A.md]]');
        expect(edited.toolEvents[1].status).assertEqual('completed');
        files.set('A.md', '后续人工编辑');
        let undoRejected: boolean = false;
        try {
          await AgentRuntime.executeManualStep(vaultId, session, edited,
            { name: 'UndoLastEdit' }, makeConfig(), TEST_REGISTRY, (_path: string): boolean => false);
        } catch (error) {
          undoRejected = (error as Error).message.indexOf('UNDO_CONFLICT') >= 0;
        }
        expect(undoRejected).assertTrue();
        expect(files.get('A.md') ?? '').assertEqual('后续人工编辑');
      });

    it('undoes the selected result, not the latest write in the vault', 0,
      async (): Promise<void> => {
        const vaultId: string = 'vault-targeted-undo-' + fixtureSerial.toString();
        files.set('A.md', 'A 原文');
        files.set('B.md', 'B 原文');
        const session: AgentSession = makeSession(vaultId);
        const writeA = await run(vaultId, session, '把这轮结论追加到笔记 [[A.md]]');
        const writeB = await run(vaultId, session, '把这轮结论追加到笔记 [[B.md]]');
        await AgentRuntime.executeManualStep(vaultId, session, writeA,
          { name: 'UndoLastEdit' }, makeConfig(), TEST_REGISTRY, (_path: string): boolean => false);
        expect(files.get('A.md') ?? '').assertEqual('A 原文');
        expect(files.get('B.md') ?? '').assertContain('阅读后的自检');
        expect(writeB.writeResult !== null).assertTrue();
      });

    it('freezes configuration for a running turn and exposes only declared mock questions', 0,
      (): void => {
        const before: AgentRunConfig = AgentConfigStore.snapshot('reading');
        AgentConfigStore.setToolEnabled('CreateNote', false);
        const after: AgentRunConfig = AgentConfigStore.snapshot('reading');
        expect(before.enabledTools.indexOf('CreateNote') >= 0).assertTrue();
        expect(after.enabledTools.indexOf('CreateNote') < 0).assertTrue();
        expect(AgentRuntime.fixedQuestions().indexOf('新建读书小结') >= 0).assertTrue();
        expect(AgentRuntime.fixedQuestions().indexOf('随便写一句') < 0).assertTrue();
        AgentConfigStore.setToolEnabled('CreateNote', true);
      });

    it('serializes vault deletion, keeps other vaults independent, and releases the lock on cleanup failure', 0,
      async (): Promise<void> => {
        let duplicateRemoved: boolean = false;
        let otherRemoved: boolean = false;
        const deleted: boolean = await AgentRuntime.deleteVaultWithCleanup('delete-lock-a',
          async (): Promise<void> => {
            expect(AgentRuntime.isVaultDeleting('delete-lock-a')).assertTrue();
            const duplicate: boolean = await AgentRuntime.deleteVaultWithCleanup('delete-lock-a',
              async (): Promise<void> => {},
              (): void => { duplicateRemoved = true; });
            expect(duplicate).assertFalse();
            const other: boolean = await AgentRuntime.deleteVaultWithCleanup('delete-lock-b',
              async (): Promise<void> => {},
              (): void => { otherRemoved = true; });
            expect(other).assertTrue();
          },
          (): void => {});
        expect(deleted).assertTrue();
        expect(AgentRuntime.isVaultDeleting('delete-lock-a')).assertFalse();
        expect(duplicateRemoved).assertFalse();
        expect(otherRemoved).assertTrue();

        let removeAfterFailure: boolean = false;
        let failed: boolean = false;
        try {
          await AgentRuntime.deleteVaultWithCleanup('delete-lock-a',
            async (): Promise<void> => { throw new Error('mock cleanup failure'); },
            (): void => { removeAfterFailure = true; });
        } catch (error) {
          failed = true;
        }
        expect(failed).assertTrue();
        expect(AgentRuntime.isVaultDeleting('delete-lock-a')).assertFalse();
        expect(removeAfterFailure).assertFalse();
        const retried: boolean = await AgentRuntime.deleteVaultWithCleanup('delete-lock-a',
          async (): Promise<void> => {},
          (): void => {});
        expect(retried).assertTrue();
      });
  });
}
