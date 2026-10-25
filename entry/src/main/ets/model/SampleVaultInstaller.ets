/** v0.5: copy shared samples only into a newly created, empty default vault. */
import { fileIo } from '@kit.CoreFileKit';
import { VaultRegistry } from './VaultRegistry';
import { NoteService } from './NoteService';
import { SAMPLE_VAULT_FILES, SampleVaultFile } from './SampleVaultData';

export class SampleVaultInstaller {
  static async install(registry: VaultRegistry): Promise<void> {
    if (!registry.consumeSampleInstall()) {
      return;
    }
    const root: string = registry.absoluteIn('local', '');
    if (fileIo.listFileSync(root).length > 0) {
      return;
    }
    for (let i = 0; i < SAMPLE_VAULT_FILES.length; i++) {
      const item: SampleVaultFile = SAMPLE_VAULT_FILES[i];
      const parts: string[] = item.path.split('/');
      for (let depth = 1; depth < parts.length; depth++) {
        const parent: string = registry.absoluteIn('local', parts.slice(0, depth).join('/'));
        if (!fileIo.accessSync(parent)) {
          fileIo.mkdirSync(parent);
        }
      }
      // Never replace a file that already exists, including an incomplete previous install.
      if (!fileIo.accessSync(registry.absoluteIn('local', item.path))) {
        await NoteService.saveNote(registry, 'local', item.path, item.content);
      }
    }
  }
}
