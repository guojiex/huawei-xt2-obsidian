import nativeGit2, { Git2ActionOptions, Git2CloneOptions, Git2Features, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';

export class GitNativeService {
  static clone(options: Git2CloneOptions): Promise<string> {
    return nativeGit2.clone(options);
  }

  static action(options: Git2ActionOptions): Promise<string> {
    return nativeGit2.gitAction(options);
  }

  static repositoryState(path: string): Git2RepositoryState {
    return nativeGit2.getRepositoryState(path);
  }

  static version(): string {
    return nativeGit2.getVersion();
  }

  static features(): Git2Features {
    return nativeGit2.getFeatures();
  }

  static progressLabel(progress: Git2Progress): string {
    if (progress.totalObjects > 0 && progress.indexedObjects >= progress.totalObjects) {
      return `解析对象 ${progress.indexedObjects}/${progress.totalObjects}`;
    }
    if (progress.totalObjects > 0) {
      return `接收对象 ${progress.receivedObjects}/${progress.totalObjects}`;
    }
    return progress.receivedBytes > 0 ? '接收 Git 数据…' : '连接远端…';
  }
}
