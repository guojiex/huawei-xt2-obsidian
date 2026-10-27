import { describe, expect, it } from '@ohos/hypium';
import { AgentOperationStorage, AgentStoredOperation } from '../main/ets/model/AgentOperationStorage';

function sampleOperation(status: 'prepared' | 'applied' | 'undoing' | 'undone' | 'aborted' | 'conflict'):
  AgentStoredOperation {
  const before: string = '旧正文';
  const after: string = '新正文';
  return {
    schemaVersion: 1,
    vaultKey: 'vault-key-1',
    conversationId: 'conversation-1',
    runId: 'run-1',
    operationId: 'agent:local:run-1:0',
    toolName: 'AppendNote',
    signature: 'AppendNote|local|note.md|新正文',
    path: 'note.md',
    before,
    after,
    baseHash: AgentOperationStorage.hashText(before),
    resultHash: AgentOperationStorage.hashText(after),
    created: false,
    status,
    createdAt: 100
  };
}

export default function agentOperationStorageTest(): void {
  describe('AgentOperationStorage', () => {
    it('accepts an operation only under its recorded stable vault, conversation, run, and ID', 0, () => {
      const operation: AgentStoredOperation = sampleOperation('prepared');
      const raw: string = JSON.stringify(operation);
      expect(AgentOperationStorage.decode(raw, 'vault-key-1', 'conversation-1', 'run-1',
        'agent:local:run-1:0') !== null).assertTrue();
      expect(AgentOperationStorage.decode(raw, 'other-vault', 'conversation-1', 'run-1',
        'agent:local:run-1:0') === null).assertTrue();
      expect(AgentOperationStorage.decode(raw, 'vault-key-1', 'conversation-1', 'run-1',
        'agent:local:run-1:1') === null).assertTrue();
    });

    it('reconciles prepared writes without replaying ambiguous content', 0, () => {
      const operation: AgentStoredOperation = sampleOperation('prepared');
      expect(AgentOperationStorage.reconcileStatus(operation, true, operation.after)).assertEqual('applied');
      expect(AgentOperationStorage.reconcileStatus(operation, true, operation.before)).assertEqual('aborted');
      expect(AgentOperationStorage.reconcileStatus(operation, true, '后续用户内容')).assertEqual('conflict');
    });

    it('reconciles interrupted undo from the actual current file version', 0, () => {
      const operation: AgentStoredOperation = sampleOperation('undoing');
      expect(AgentOperationStorage.reconcileStatus(operation, true, operation.before)).assertEqual('undone');
      expect(AgentOperationStorage.reconcileStatus(operation, true, operation.after)).assertEqual('applied');
      expect(AgentOperationStorage.reconcileStatus(operation, true, '其他内容')).assertEqual('conflict');
    });

    it('recognizes an interrupted create only when the expected content is present', 0, () => {
      const operation: AgentStoredOperation = sampleOperation('prepared');
      operation.created = true;
      operation.before = '';
      operation.baseHash = AgentOperationStorage.hashText('');
      expect(AgentOperationStorage.reconcileStatus(operation, true, operation.after)).assertEqual('applied');
      expect(AgentOperationStorage.reconcileStatus(operation, false, '')).assertEqual('aborted');
      expect(AgentOperationStorage.reconcileStatus(operation, true, '')).assertEqual('conflict');
    });
  });
}
