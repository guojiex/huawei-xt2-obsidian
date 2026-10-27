import { describe, expect, it } from '@ohos/hypium';
import { AgentConfigStore } from '../main/ets/model/AgentConfigStore';

export default function agentConfigStoreTest(): void {
  describe('AgentConfigStore persistence format', () => {
    it('decodes versioned custom prompt, Skill overrides, and enabled tools', 0, () => {
      const raw: string = '{"schemaVersion":1,"configRevision":7,' +
        '"systemPrompt":{"mode":"custom","baseRevision":"builtin-1","customText":"自定义提示词"},' +
        '"defaultSkillId":"reading","skillOverrides":{"reading":"自定义读书 Skill"},' +
        '"enabledTools":["ReadNote","QueryNotes"]}';
      const value = AgentConfigStore.decode(raw);
      expect(value !== null).assertTrue();
      expect(value === null ? 0 : value.configRevision).assertEqual(7);
      expect(value === null ? '' : value.systemPrompt.customText).assertEqual('自定义提示词');
      expect(value === null ? '' : value.skillOverrides['reading']).assertEqual('自定义读书 Skill');
      expect(value === null ? 0 : value.enabledTools.length).assertEqual(2);
    });

    it('rejects corrupt and unsupported settings without replacing their source text', 0, () => {
      expect(AgentConfigStore.decode('{broken') === null).assertTrue();
      const future: string = '{"schemaVersion":2,"configRevision":1}';
      expect(AgentConfigStore.decode(future) === null).assertTrue();
    });
  });
}
