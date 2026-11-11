export type ShareFailurePhase = 'image_prepare' | 'text_prepare' | 'file_prepare' | 'handoff';

// 2026-11-11 用户拍板：数据是用户自己的，分享失败直接展示真实错误信息——
// 白名单放行、前缀改写与「原因未确定」替换兜底全部移除，真实错误不再被吞掉
// （同 34.5「自己的应用，别把用户当外人」裁定）。仅当异常没有可展示的
// message 时，才回落到带恢复建议的阶段性说明。
export function shareFailureMessage(error: Object, phase: ShareFailurePhase): string {
  const message: string = error instanceof Error ? error.message : '';
  if (message.length > 0) {
    return message;
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
