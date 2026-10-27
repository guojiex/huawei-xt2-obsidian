import { describe, expect, it } from '@ohos/hypium';
import { AgentConversationStorage } from '../main/ets/model/AgentConversationStorage';
import { AgentSession } from '../main/ets/model/AgentModels';
import { VaultPathResolver } from '../main/ets/model/VaultPathResolver';
import { common } from '@kit.AbilityKit';

interface TestConversationDocument {
  schemaVersion: number;
  vaultKey: string;
  session: AgentSession;
}

interface TestPathContext {
  filesDir: string;
  cacheDir: string;
}

export default function agentConversationStorageTest(): void {
  describe('AgentConversationStorage', () => {
    it('loads a conversation only for its stable vault key and remaps renamed vault ownership', 0, () => {
      const session: AgentSession = {
        id: 'conversation-1',
        vaultId: 'old-vault-name',
        title: '手工标题',
        titleManuallySet: true,
        archived: false,
        skillId: 'reading',
        draft: '未发送草稿',
        messages: [],
        updatedAt: 100
      };
      const document: TestConversationDocument = {
        schemaVersion: 1,
        vaultKey: 'vault-stable-1',
        session
      };
      const raw: string = JSON.stringify(document);

      const loaded = AgentConversationStorage.decode(raw, 'vault-stable-1', 'renamed-vault', 'conversation-1');
      expect(loaded !== null).assertTrue();
      expect(loaded === null ? '' : loaded.vaultId).assertEqual('renamed-vault');
      expect(loaded === null ? '' : loaded.draft).assertEqual('未发送草稿');
      expect(loaded === null ? false : loaded.titleManuallySet === true).assertTrue();
      expect(AgentConversationStorage.decode(raw, 'another-vault', 'renamed-vault', 'conversation-1') === null)
        .assertTrue();
    });

    it('preserves malformed or incompatible conversation JSON by refusing to decode it', 0, () => {
      expect(AgentConversationStorage.decode('{broken', 'vault-1', 'local', 'conversation-1') === null).assertTrue();
      const session: AgentSession = {
        id: 'conversation-1',
        vaultId: 'local',
        title: '未来记录',
        skillId: 'reading',
        draft: '',
        messages: []
      };
      const futureDocument: TestConversationDocument = { schemaVersion: 2, vaultKey: 'vault-1', session };
      const future: string = JSON.stringify(futureDocument);
      expect(AgentConversationStorage.decode(future, 'vault-1', 'local', 'conversation-1') === null).assertTrue();
    });

    it('resolves Agent private storage below filesDir using safe path segments', 0, () => {
      const fixture: TestPathContext = { filesDir: '/sandbox/files', cacheDir: '/sandbox/cache' };
      const context = fixture as Object as common.UIAbilityContext;
      const resolver: VaultPathResolver = new VaultPathResolver(context);
      expect(resolver.agentConversationFile('vault-key', 'conversation-1'))
        .assertEqual('/sandbox/files/app/agent/vaults/vault-key/conversations/conversation-1/conversation.json');
      expect(resolver.agentRunStateFile('vault-key', 'conversation-1', 'run-1'))
        .assertEqual('/sandbox/files/app/agent/vaults/vault-key/conversations/conversation-1/runs/run-1/state.json');
      expect(resolver.agentOperationFile('vault-key', 'conversation-1', 'run-1', 'agent:local:run-1:0'))
        .assertEqual('/sandbox/files/app/agent/vaults/vault-key/conversations/conversation-1/runs/run-1/' +
          'operations/agent:local:run-1:0.json');
      let rejected: boolean = false;
      try {
        resolver.agentConversationFile('../escape', 'conversation-1');
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
