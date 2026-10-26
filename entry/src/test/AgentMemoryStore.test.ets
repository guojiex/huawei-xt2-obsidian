import { describe, expect, it } from '@ohos/hypium';
import { AgentMemoryStore } from '../main/ets/model/AgentMemoryStore';
import { AgentSession } from '../main/ets/model/AgentModels';

let storeTestSerial: number = 0;

function newVaultId(): string {
  storeTestSerial++;
  return 'agent-store-test-' + Date.now().toString() + '-' + storeTestSerial.toString();
}

export default function agentMemoryStoreTest(): void {
  describe('AgentMemoryStore lifecycle', () => {
    it('renames with trimmed title and rejects an empty title', 0, () => {
      const vaultId: string = newVaultId();
      const session: AgentSession = AgentMemoryStore.create(vaultId);

      expect(AgentMemoryStore.rename(vaultId, session.id, '  阅读问题  ')).assertTrue();
      expect(session.title).assertEqual('阅读问题');
      expect(session.titleManuallySet).assertTrue();
      expect(AgentMemoryStore.rename(vaultId, session.id, '   ')).assertFalse();
      expect(session.title).assertEqual('阅读问题');
    });

    it('archives the active session and selects a non-archived successor', 0, () => {
      const vaultId: string = newVaultId();
      const older: AgentSession = AgentMemoryStore.create(vaultId);
      const active: AgentSession = AgentMemoryStore.create(vaultId);

      expect(AgentMemoryStore.archive(vaultId, active.id)).assertTrue();
      expect(AgentMemoryStore.active(vaultId).id).assertEqual(older.id);
      expect(AgentMemoryStore.recent(vaultId).length).assertEqual(1);
      expect(AgentMemoryStore.get(vaultId, active.id)?.archived).assertTrue();
    });

    it('restores an archived session and refuses to activate it before restoration', 0, () => {
      const vaultId: string = newVaultId();
      const session: AgentSession = AgentMemoryStore.create(vaultId);

      expect(AgentMemoryStore.archive(vaultId, session.id)).assertTrue();
      expect(AgentMemoryStore.activate(vaultId, session.id) === null).assertTrue();
      expect(AgentMemoryStore.restore(vaultId, session.id)).assertTrue();
      expect(AgentMemoryStore.activate(vaultId, session.id)?.id).assertEqual(session.id);
    });

    it('deletes only the selected vault session and creates a blank successor', 0, () => {
      const vaultId: string = newVaultId();
      const otherVaultId: string = newVaultId();
      const session: AgentSession = AgentMemoryStore.create(vaultId);
      const otherVaultSession: AgentSession = AgentMemoryStore.create(otherVaultId);

      expect(AgentMemoryStore.remove(vaultId, session.id)).assertTrue();
      expect(AgentMemoryStore.get(vaultId, session.id) === null).assertTrue();
      expect(AgentMemoryStore.active(vaultId).messages.length).assertEqual(0);
      expect(AgentMemoryStore.get(otherVaultId, otherVaultSession.id) !== null).assertTrue();
      expect(AgentMemoryStore.remove(vaultId, session.id)).assertFalse();
    });
  });
}
