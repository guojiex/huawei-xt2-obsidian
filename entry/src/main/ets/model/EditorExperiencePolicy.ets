export type EditorExperienceMode = 'simple' | 'professional';

export const DEFAULT_EDITOR_EXPERIENCE: EditorExperienceMode = 'simple';

export function readEditorExperience(read: () => string): EditorExperienceMode {
  try {
    return read() === 'professional' ? 'professional' : DEFAULT_EDITOR_EXPERIENCE;
  } catch (error) {
    return DEFAULT_EDITOR_EXPERIENCE;
  }
}

export function writeEditorExperience(mode: EditorExperienceMode, write: (value: string) => void): boolean {
  if (mode !== 'simple' && mode !== 'professional') {
    return false;
  }
  try {
    write(mode);
    return true;
  } catch (error) {
    return false;
  }
}
