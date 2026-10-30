import abilityTest from './Ability.test';
import gitImportTest from './GitImport.test';
import git2NativeTest from './Git2Native.test';

export default function testsuite() {
  abilityTest();
  gitImportTest();
  git2NativeTest();
}
