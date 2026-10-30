export function preservedScrollTop(
  currentScrollTop: number,
  anchorScreenTop: number,
  viewportTop: number,
  anchorViewportY: number,
  scrollHeight: number,
  clientHeight: number
): number {
  const maxScrollTop: number = Math.max(0, scrollHeight - clientHeight);
  const nextScrollTop: number = currentScrollTop + anchorScreenTop - viewportTop - anchorViewportY;
  return Math.max(0, Math.min(maxScrollTop, nextScrollTop));
}
