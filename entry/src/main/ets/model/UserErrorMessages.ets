export type ShareFailurePhase = 'image_prepare' | 'text_prepare' | 'file_prepare' | 'handoff';

const SAFE_SHARE_MESSAGES: string[] = [
  '分享预览没有可用的页面尺寸',
  '笔记超过单张长图分享上限；请改用 Markdown / ZIP',
  '无法确定长图尺寸，请改用 Markdown / ZIP',
  '笔记过长，无法生成清晰的单张长图；请改用 Markdown / ZIP',
  '长图分段位置无效',
  '长图分段超出目标图片范围',
  '长图分段缩放尺寸不匹配',
  '长图分段尺寸不足，无法覆盖全文',
  '分享预览加载超时，请重试',
  '文本超过系统分享 200 KB 限制，请删减内容后重试或改用 Markdown / ZIP。',
  '文件夹层级超过分享上限，未生成分享文件',
  '所选路径不是可分享的文件夹'
];

export function shareFailureMessage(error: Object, phase: ShareFailurePhase): string {
  const message: string = error instanceof Error ? error.message : '';
  if (SAFE_SHARE_MESSAGES.indexOf(message) >= 0) {
    return message;
  }
  if (message.startsWith('缺少本地图片，未生成分享文件：') ||
    message.startsWith('本地图片不是普通文件，未生成分享文件：') ||
    message.startsWith('图片路径越界或属于内部目录，未生成分享文件：') ||
    message.startsWith('图片位于不分享的应用内部目录，未生成分享文件：')) {
    return '分享文件准备失败：笔记中的图片缺失或不可用；请检查图片引用后重试。原笔记未修改。';
  }
  switch (phase) {
    case 'image_prepare':
      return '长图准备失败；原笔记未修改。原因未确定，请重试或改用 Markdown / ZIP。';
    case 'text_prepare':
      return '文本准备失败；原笔记未修改。原因未确定，请重试。';
    case 'file_prepare':
      return '文件准备失败；知识库未修改。原因未确定，请检查访问状态和本地空间后重试。';
    default:
      return '系统分享交接未完成；接收端状态未知。原因未确定，请重试或选择其他格式。';
  }
}
