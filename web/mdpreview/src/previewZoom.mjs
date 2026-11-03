export const PREVIEW_ZOOM_PRESETS = [50, 75, 100, 125, 150, 175, 200]

export function normalizePreviewZoomPercent(value) {
  if (!Number.isFinite(value)) {
    return 100
  }
  return Math.max(50, Math.min(200, Math.round(value)))
}
