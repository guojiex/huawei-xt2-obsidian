import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { ShareIngestPayload, ShareIngestService } from './ShareIngestService';

const DOMAIN = 0x0000;
const TAG = 'EntryAbility';

/**
 * ShareIngestDevice.ets —— v1.56 56.2 分享拉起解析的设备层（@kit.ShareKit 调用本体）。
 *
 * 2026-11-15 冷启动优化（XT2 trace）：systemShare（@kit.ShareKit）属启动期未用模块
 * （82 个之一），从 EntryAbility 拆到本文件，由 EntryAbility 在 want.action 为
 * sendData 时动态 import —— 分享拉起才加载。解析逻辑自 EntryAbility 原样搬移：
 * - 只取第一条 utd 为文本/链接且 content 非空的记录（批量不做，56.2）；
 * - 无有效记录 / getSharedData 抛错（1003703001 等）→ 不崩溃，返回错误载荷，
 *   Index 侧 toast「无法读取分享内容」；
 * - 红线（56.5）：标题与内容不进日志、不进埋点，日志只记记录数与错误码。
 */
export async function resolveSharedWantPayload(want: Want): Promise<ShareIngestPayload> {
  try {
    const shared: systemShare.SharedData = await systemShare.getSharedData(want);
    const records: Array<systemShare.SharedRecord> = shared.getRecords();
    let chosen: systemShare.SharedRecord | null = null;
    for (let i = 0; i < records.length; i++) {
      const record: systemShare.SharedRecord = records[i];
      if (!ShareIngestService.isTextLikeUtd(record.utd)) {
        continue;
      }
      if ((record.content ?? '').trim().length === 0) {
        continue;
      }
      chosen = record;
      break;
    }
    hilog.info(DOMAIN, TAG, '分享记录数=%{public}d 有效=%{public}s',
      records.length, chosen === null ? '否' : '是');
    if (chosen === null) {
      return ShareIngestService.errorPayload('无法读取分享内容', Date.now());
    }
    const payload: ShareIngestPayload = {
      utd: chosen.utd,
      title: chosen.title ?? '',
      content: chosen.content ?? '',
      message: '',
      receivedAt: Date.now()
    };
    return payload;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, '读取分享数据失败 code=%{public}d', err.code);
    return ShareIngestService.errorPayload('无法读取分享内容', Date.now());
  }
}
