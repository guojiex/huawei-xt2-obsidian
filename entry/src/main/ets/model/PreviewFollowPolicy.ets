export interface PreviewFollowContext {
  topView: string;
  vaultId: string;
  leftPath: string;
  rightPath: string;
  leftEditing: boolean;
  rightEditing: boolean;
  bothPanesVisible: boolean;
}

export interface PreviewFollowPair {
  key: string;
  sourcePane: string;
  previewPane: string;
}

export interface PreviewFollowAnchor {
  line: number;
  lineProgress: number;
  viewportRatio: number;
  atStart: boolean;
  atEnd: boolean;
}

export function resolvePreviewFollowPair(context: PreviewFollowContext): PreviewFollowPair | null {
  if (context.topView !== 'note' || !context.bothPanesVisible || context.vaultId.length === 0 ||
    context.leftPath.length === 0 || context.leftPath !== context.rightPath ||
    context.leftEditing === context.rightEditing) {
    return null;
  }

  const sourcePane: string = context.leftEditing ? 'left' : 'right';
  const previewPane: string = context.leftEditing ? 'right' : 'left';
  const key: string = `${context.vaultId.length}:${context.vaultId}${context.leftPath.length}:${context.leftPath}${sourcePane}`;
  return { key, sourcePane, previewPane };
}
