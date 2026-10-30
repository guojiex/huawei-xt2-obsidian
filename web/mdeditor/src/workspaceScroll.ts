export interface ScrollContainer {
  scrollTop: number
  scrollHeight: number
  clientHeight: number
}

export function editorWorkspaceScrollContainer(editor: ScrollContainer,
  documentScroller: ScrollContainer): ScrollContainer {
  return editor.scrollHeight > editor.clientHeight ? editor : documentScroller
}

export function clampWorkspaceScrollTop(container: ScrollContainer, top: number): number {
  const safeTop = Number.isFinite(top) ? Math.max(0, top) : 0
  return Math.min(safeTop, Math.max(0, container.scrollHeight - container.clientHeight))
}
