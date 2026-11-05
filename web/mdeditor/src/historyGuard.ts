export function historySnapshotMatches(currentContent: string, expectedContent: string,
  currentRevision: number, expectedRevision: number): boolean {
  return currentRevision === expectedRevision && currentContent === expectedContent
}
