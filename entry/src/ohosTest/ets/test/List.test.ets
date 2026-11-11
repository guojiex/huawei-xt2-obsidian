import abilityTest from './Ability.test';
import gitImportTest from './GitImport.test';
import gitCredentialStoreTest from './GitCredentialStore.test';
import git2NativeTest from './Git2Native.test';
import uiLaunchTest from './ui/UiLaunch.test';
import uiNoteFlowTest from './ui/UiNoteFlow.test';
import uiPanelsTest from './ui/UiPanels.test';
import uiQuickSwitchTest from './ui/UiQuickSwitch.test';
import uiSmDrawerTest from './ui/UiSmDrawer.test';
import uiTrashTest from './ui/UiTrash.test';
import uiSettingsExtTest from './ui/UiSettingsExt.test';
import uiShareTest from './ui/UiShare.test';

export default function testsuite() {
  abilityTest();
  gitImportTest();
  gitCredentialStoreTest();
  git2NativeTest();
  // UI 自动化套件（docs/testing/UI自动化测试.md）：只在模拟器/真机上有意义，
  // 本地atest跑单测时按 -s class 过滤排除即可
  uiLaunchTest();
  uiNoteFlowTest();
  uiPanelsTest();
  uiQuickSwitchTest();
  uiSmDrawerTest();
  uiTrashTest();
  uiSettingsExtTest();
  uiShareTest();
}
