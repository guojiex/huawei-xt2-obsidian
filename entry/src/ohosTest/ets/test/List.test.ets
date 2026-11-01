import abilityTest from './Ability.test';
import gitImportTest from './GitImport.test';
import gitCredentialStoreTest from './GitCredentialStore.test';
import git2NativeTest from './Git2Native.test';

export default function testsuite() {
  abilityTest();
  gitImportTest();
  gitCredentialStoreTest();
  git2NativeTest();
}
