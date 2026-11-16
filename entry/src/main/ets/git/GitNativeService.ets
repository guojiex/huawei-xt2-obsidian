import { Git2ActionOptions, Git2CloneOptions, Git2DiffOptions, Git2Features, Git2FileDiffs, Git2Progress, Git2RepositoryState } from 'libgit2_napi.so';

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

  // v1.69：置位 native 取消标志中止进行中的 clone。native 侧在新 clone 排队前
  // 复位标志，本方法只在 clone 运行期调用（见 ImportVaultDialog「取消导入」）。
  static async cancelClone(): Promise<void> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: () => void = native.cancelClone;
    fn();
  }

  static async repositoryState(path: string, targetBranch: string = 'xt2'): Promise<Git2RepositoryState> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: (path: string, targetBranch: string) => Git2RepositoryState = native.getRepositoryState;
    return fn(path, targetBranch);
  }

  // v1.75：读取未提交改动（HEAD vs 工作区）的逐行差异。同步导出，包在 async 中
  // 与其余 native 调用一致，并让调用方 await 时不阻塞 UI 线程编排。
  static async fileDiffs(path: string, options?: Git2DiffOptions): Promise<Git2FileDiffs> {
    const native: ESObject = await GitNativeService.nativeModule();
    const fn: (path: string, options?: Git2DiffOptions) => Git2FileDiffs = native.getFileDiffs;
    return options === undefined ? fn(path) : fn(path, options);
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
