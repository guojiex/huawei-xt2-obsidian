import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { afterAll, beforeAll, describe, expect, it } from '@ohos/hypium';
import {
  formatRecentError, formatRecentErrorsForCopy, parseRecentErrorSnapshot, RecentErrorRecord,
  RecentErrorStore, serializeRecentErrorSnapshot
} from '../main/ets/model/RecentErrorStore';

let appContext: common.UIAbilityContext;
let testPreferences: preferences.Preferences;
let testPreferencesName: string = '';

export default function recentErrorStoreTest(): void {
  describe('RecentErrorStore', () => {
    beforeAll((): void => {
      appContext = abilityDelegatorRegistry.getAbilityDelegator().getAppContext() as common.UIAbilityContext;
      testPreferencesName = 'recent_error_test_' + Date.now().toString();
      testPreferences = preferences.getPreferencesSync(appContext, { name: testPreferencesName });
    });

    afterAll((): void => {
      try {
        testPreferences.clearSync();
        testPreferences.flushSync();
      } catch (error) {
        // The test uses a unique Preferences name and never touches production diagnostics.
      }
    });

    it('persists allowlisted records and reloads them from Preferences', 0, (): void => {
      const store: RecentErrorStore = new RecentErrorStore(appContext, testPreferences);
      const empty: RecentErrorRecord[] | null = store.load();
      expect(empty === null ? -1 : empty.length).assertEqual(0);
      expect(store.recordFailure('settings', 'build_commit_copy', 'clipboard_failure',
        'not_completed', 'retry')).assertTrue();

      const reopenedPreferences: preferences.Preferences =
        preferences.getPreferencesSync(appContext, { name: testPreferencesName });
      const reopenedStore: RecentErrorStore = new RecentErrorStore(appContext, reopenedPreferences);
      const records: RecentErrorRecord[] | null = reopenedStore.load();
      expect(records === null ? -1 : records.length).assertEqual(1);
      expect(records === null ? '' : formatRecentError(records[0])).assertContain('复制构建提交号');
      expect(records === null ? '' : formatRecentErrorsForCopy(records)).assertContain('下一步：稍后重试');
    });

    it('keeps only the newest twenty records', 0, (): void => {
      testPreferences.clearSync();
      testPreferences.flushSync();
      const store: RecentErrorStore = new RecentErrorStore(appContext, testPreferences);
      for (let i: number = 0; i < RecentErrorStore.LIMIT + 1; i++) {
        expect(store.recordFailure('settings', 'recent_errors_copy', 'clipboard_failure',
          'not_completed', 'retry')).assertTrue();
      }
      const records: RecentErrorRecord[] | null = store.load();
      expect(records === null ? -1 : records.length).assertEqual(RecentErrorStore.LIMIT);
      const raw: string = testPreferences.getSync('latest', '') as string;
      expect(raw.length <= RecentErrorStore.MAX_SERIALIZED_LENGTH).assertTrue();
    });

    it('rejects unsupported records and serializes only the declared fields', 0, (): void => {
      const raw: string = '{"schemaVersion":1,"records":[{"timestamp":1,' +
        '"operation":"settings","phase":"build_commit_copy","category":"clipboard_failure",' +
        '"outcome":"not_completed","nextStep":"retry","privateText":"must-not-survive"}]}';
      const parsed = parseRecentErrorSnapshot(raw);
      expect(parsed === null ? -1 : parsed.records.length).assertEqual(1);
      const encoded: string = parsed === null ? '' : serializeRecentErrorSnapshot(parsed.records);
      expect(encoded.includes('privateText')).assertFalse();
      expect(parseRecentErrorSnapshot('{"schemaVersion":2,"records":[]}') === null).assertTrue();
      let oversized: string = '';
      for (let i: number = 0; i <= RecentErrorStore.MAX_SERIALIZED_LENGTH; i++) {
        oversized += 'x';
      }
      expect(parseRecentErrorSnapshot(oversized) === null).assertTrue();
    });
  });
}
