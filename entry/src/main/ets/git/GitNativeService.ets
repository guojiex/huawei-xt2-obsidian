import { Git2ActionOptions, Git2CloneOptions, Git2Features, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';

export class GitNativeService {
  // 冷启动优化（2026-11-15，XT2 trace）：libgit2_napi.so 随启动图静态加载但启动期无人调用，
  // 改为首次调用时动态 import（官方 FAQ faqs-ndk-4：await import('libentry.so') 后经 .default 取导出）。
  // 上方类型 import 仅用于方法签名，编译期消除，不再触发 so 的 dlopen。
  private static async nativeModule(): Promise<ESObject> {
    const mod: ESObject = await import('libgit2_napi.so');
    return mod.default;
  }

  static async clone(options: Git2CloneOptions): Promise<string> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: (options: Git2CloneOptions) => Promise<string> = native.clone;
    return fn(options);
  }

  static async action(options: Git2ActionOptions): Promise<string> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: (options: Git2ActionOptions) => Promise<string> = native.gitAction;
    return fn(options);
  }

  static async repositoryState(path: string, targetBranch: string = 'xt2'): Promise<Git2RepositoryState> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: (path: string, targetBranch: string) => Git2RepositoryState = native.getRepositoryState;
    return fn(path, targetBranch);
  }

  static async version(): Promise<string> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: () => string = native.getVersion;
    return fn();
  }

  static async features(): Promise<Git2Features> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: () => Git2Features = native.getFeatures;
    return fn();
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
