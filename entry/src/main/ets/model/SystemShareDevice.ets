import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import fileUri from '@ohos.file.fileuri';

/**
 * SystemShareDevice.ets —— 系统分享面板（@kit.ShareKit）设备层。
 *
 * 2026-11-15 冷启动优化（XT2 trace）：systemShare（@kit.ShareKit）属启动期未用模块
 * （82 个之一），从 ShareFlowPanel 拆到本文件，由调用方动态 import —— 用户真正
 * 点分享时才加载。四个入口的 SharedData 构造字段与 ShareController.show 参数自
 * 原调用点逐字段搬移，行为零变化（label / uri / title 语义不变）。
 */
export async function showFileShareSheet(filePath: string, title: string, utd: string,
  context: common.UIAbilityContext): Promise<void> {
  const shared = new systemShare.SharedData({
    utd: utd,
    uri: fileUri.getUriFromPath(filePath),
    title: title
  });
  await new systemShare.ShareController(shared).show(context, {});
}

export async function showLinkShareSheet(url: string, title: string,
  context: common.UIAbilityContext): Promise<void> {
  const shared = new systemShare.SharedData({
    utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
    content: url,
    title: title,
    label: 'HYPERLINK'
  });
  await new systemShare.ShareController(shared).show(context, {});
}

export async function showTextShareSheet(content: string, title: string,
  context: common.UIAbilityContext): Promise<void> {
  const shared = new systemShare.SharedData({
    utd: uniformTypeDescriptor.UniformDataType.TEXT,
    content: content,
    title: title,
    label: 'TEXT'
  });
  await new systemShare.ShareController(shared).show(context, {});
}

export async function showImageShareSheet(uri: string, title: string,
  context: common.UIAbilityContext): Promise<void> {
  const shared = new systemShare.SharedData({
    utd: uniformTypeDescriptor.UniformDataType.JPEG,
    uri: uri,
    title: title,
    label: 'IMAGE'
  });
  await new systemShare.ShareController(shared).show(context, {});
}
