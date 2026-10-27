import { describe, it, expect } from '@ohos/hypium';
import { NoteImageService } from '../main/ets/model/NoteImageService';

export default function noteImageImportTest() {
  describe('noteImageImportTest', () => {
    it('accepts only a non-empty complete copied image', 0, () => {
      NoteImageService.validateCopiedSize(64, 64);
      let rejected: boolean = false;
      try {
        NoteImageService.validateCopiedSize(64, 32);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();

      rejected = false;
      try {
        NoteImageService.validateCopiedSize(0, 0);
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}
