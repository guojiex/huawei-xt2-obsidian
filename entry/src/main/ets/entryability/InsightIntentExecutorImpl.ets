import { common, insightIntent, InsightIntentExecutor } from '@kit.AbilityKit';
import { InsightIntentNoteService } from './InsightIntentNoteService';
import { VaultEntry } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';

interface VaultSummary {
  vaultId: string;
  name: string;
  type: 'local' | 'git';
  isCurrent: boolean;
}

/** Insight Intent 后台端插件执行器。 */
export default class InsightIntentExecutorImpl extends InsightIntentExecutor {
  async onExecuteInUIAbilityBackgroundMode(name: string,
    param: Record<string, Object>): Promise<insightIntent.ExecuteResult> {
    // v1.16：SearchNotes / ListTree / GetLinks 为端侧只读路由；平台工具创建与绑定不在本版范围
    // （见 docs/releases/v1.16/需求文档.md §3），未登记进 insight_intent.json 前不会被平台调用。
    const isNoteTool: boolean = name === 'QueryNotes' || name === 'ReadNote' || name === 'CreateNote' ||
      name === 'AppendNote' || name === 'EditNote' || name === 'UndoLastEdit' ||
      name === 'SearchNotes' || name === 'ListTree' || name === 'GetLinks';
    if (name !== 'ListVaults' && name !== 'CreateVault' && !isNoteTool) {
      return {
        code: -1,
        result: { message: '不支持的端插件工具。' }
      };
    }

    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const registry: VaultRegistry = VaultRegistry.initialize(context);
      if (isNoteTool) {
        const result: Record<string, Object> = await new InsightIntentNoteService(registry).execute(name, param);
        return { code: 0, result };
      }
      if (name === 'CreateVault') {
        const requestedName: Object = param['name'];
        if (typeof requestedName !== 'string' || requestedName.trim().length === 0) {
          return {
            code: -1,
            result: { message: '库名不能为空。' }
          };
        }
        const entry: VaultEntry = registry.createLocal(requestedName);
        return {
          code: 0,
          result: {
            vaultId: entry.id,
            name: entry.id,
            type: entry.type,
            message: '已创建本地知识库「' + entry.id + '」，当前库未切换。'
          }
        };
      }

      const currentVaultId: string = registry.currentId();
      const entries: VaultEntry[] = registry.list();
      const vaults: VaultSummary[] = [];
      for (let i = 0; i < entries.length; i++) {
        const entry: VaultEntry = entries[i];
        if (entry.type !== 'local' && entry.type !== 'git') {
          continue;
        }
        vaults.push({
          vaultId: entry.id,
          name: entry.id,
          type: entry.type,
          isCurrent: entry.id === currentVaultId
        });
      }
      return {
        code: 0,
        result: {
          vaultsJson: JSON.stringify(vaults),
          message: '已找到 ' + vaults.length.toString() + ' 个已注册知识库。'
        }
      };
    } catch (_error) {
      let message: string = '笔记操作失败；操作完成状态未确认。原因未确定，请在应用内检查目标笔记和操作记录后再决定是否重试。';
      if (name === 'CreateVault') {
        message = '创建知识库失败；创建结果未确认。原因未确定，请检查知识库列表后再决定是否重试。';
      } else if (name === 'ListVaults') {
        message = '读取知识库列表失败；知识库未修改。原因未确定，请稍后重试查询。';
      }
      return {
        code: -1,
        result: { message }
      };
    }
  }
}
