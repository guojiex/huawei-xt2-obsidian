import { afterAll, describe, expect, it } from '@ohos/hypium';
import { GitCredentialStore } from '../../../main/ets/git/GitCredentialStore';

const testVaultIds: string[] = [];
let serial: number = 0;

function newTestVaultId(label: string): string {
  serial++;
  const id: string = 'codex_asset_runtime_' + Date.now().toString() + '_' + serial.toString() + '_' + label;
  testVaultIds.push(id);
  return id;
}

export default function gitCredentialStoreTest() {
  describe('GitCredentialStore_AssetStoreKitRuntime', () => {
    afterAll(() => {
      for (let i: number = 0; i < testVaultIds.length; i++) {
        GitCredentialStore.removeToken(testVaultIds[i]);
      }
    });

    it('stores, overwrites, isolates, migrates, and removes synthetic tokens', 0, (): void => {
      const originalId: string = newTestVaultId('original');
      const unrelatedId: string = newTestVaultId('unrelated');
      const renamedId: string = newTestVaultId('renamed');
      const firstToken: string = 'synthetic-test-token-one';
      const replacementToken: string = 'synthetic-test-token-two';

      try {
        expect(GitCredentialStore.getToken(originalId)).assertEqual(null);
        GitCredentialStore.saveToken(originalId, firstToken);
        expect(GitCredentialStore.getToken(originalId)).assertEqual(firstToken);

        GitCredentialStore.saveToken(originalId, replacementToken);
        expect(GitCredentialStore.getToken(originalId)).assertEqual(replacementToken);
        expect(GitCredentialStore.getToken(unrelatedId)).assertEqual(null);

        GitCredentialStore.migrateToken(originalId, renamedId);
        expect(GitCredentialStore.getToken(originalId)).assertEqual(null);
        expect(GitCredentialStore.getToken(renamedId)).assertEqual(replacementToken);

        GitCredentialStore.removeToken(renamedId);
        GitCredentialStore.removeToken(renamedId);
        expect(GitCredentialStore.getToken(renamedId)).assertEqual(null);
      } finally {
        GitCredentialStore.removeToken(originalId);
        GitCredentialStore.removeToken(unrelatedId);
        GitCredentialStore.removeToken(renamedId);
      }
    });
  });
}
