export interface SaveFeedbackContext {
  contentReadSucceeded: boolean;
  writeSucceeded: boolean;
  feedbackEnabled: boolean;
  saveRevisionCurrent: boolean;
  noteViewActive: boolean;
  targetCurrent: boolean;
}

export function shouldShowSaveFeedback(context: SaveFeedbackContext): boolean {
  return context.contentReadSucceeded && context.writeSucceeded && context.feedbackEnabled &&
    context.saveRevisionCurrent &&
    context.noteViewActive && context.targetCurrent;
}
