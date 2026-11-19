/**
 * MarkdownOpenDevice.ets —— v1.89 设备层：从临时授权的文件 URI 当次读取文本（零落盘）。
 *
 * 从 EntryAbility / MarkdownViewAbility 动态 import —— 只有 viewData 拉起才加载 fileIo，
 * 冷启动常规路径零成本（同 v1.56 ShareIngestDevice 的拆分理由）。
 *
 * 官方依据（api_notes AF4/AF6）：want.uri 是临时授权，应用退出 / 重启即失效；只读预览
 * 当次读一次即渲染，不拷进沙箱长期持有，零新增权限。
 * fileIo.openSync 支持 URI（SDK `@ohos.file.fs.d.ts`：path = 沙箱路径或文件 URI）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { MarkdownOpenService, MarkdownOpenPayload } from './MarkdownOpenService';

const DOMAIN = 0x0000;
const TAG = 'MarkdownOpenDevice';

/** 读临时授权 URI 的文本内容，按大小上限决定全量 / 截断 / 拒绝。 */
export function readMarkdownUri(uri: string, fileName: string, receivedAt: number): MarkdownOpenPayload {
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    const stat: fileIo.Stat = fileIo.statSync(file.fd);
    const size: number = stat.size;
    if (size <= 0) {
      return MarkdownOpenService.contentPayload(fileName, '', false, receivedAt);
    }
    const overLimit: boolean = MarkdownOpenService.isOverLimit(size);
    const readLimit: number = overLimit
      ? Math.min(MarkdownOpenService.MAX_PREVIEW_BYTES, size)
      : size;
    const bytes: Uint8Array = new Uint8Array(readLimit);
    let readTotal: number = 0;
    while (readTotal < readLimit) {
      const chunk: ArrayBuffer = new ArrayBuffer(readLimit - readTotal);
      const read: number = fileIo.readSync(file.fd, chunk);
      if (read <= 0 || read > chunk.byteLength) {
        throw new Error('short read');
      }
      bytes.set(new Uint8Array(chunk, 0, read), readTotal);
      readTotal += read;
    }
    const safe: Uint8Array = overLimit
      ? MarkdownOpenService.truncateUtf8Bytes(bytes, MarkdownOpenService.MAX_PREVIEW_BYTES)
      : bytes;
    const content: string = new util.TextDecoder().decodeToString(safe);
    return MarkdownOpenService.contentPayload(fileName, content, overLimit, receivedAt);
  } catch (error) {
    const err = error as BusinessError;
    // 只记错误码，路径 / 文件名 / 内容一律不进日志（硬约束 16）。
    hilog.error(DOMAIN, TAG, '读取打开文件失败 code=%{public}d', err.code ?? 0);
    return MarkdownOpenService.errorPayload(fileName, '无法读取该文件内容', receivedAt);
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (_error) {
        hilog.warn(DOMAIN, TAG, '关闭打开文件失败');
      }
    }
  }
}
