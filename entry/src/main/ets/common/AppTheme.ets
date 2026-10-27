import { ConfigurationConstant } from '@kit.AbilityKit';

export type AppTheme = 'light' | 'dark';

export function appThemeForColorMode(colorMode: ConfigurationConstant.ColorMode | undefined): AppTheme {
  return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light';
}
