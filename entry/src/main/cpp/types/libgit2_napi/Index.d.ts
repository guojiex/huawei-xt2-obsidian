export interface Git2Features {
  threads: boolean;
  https: boolean;
  ssh: boolean;
}

export interface Git2Progress {
  totalObjects: number;
  indexedObjects: number;
  receivedObjects: number;
  localObjects: number;
  totalDeltas: number;
  indexedDeltas: number;
  receivedBytes: number;
}

export interface Git2CloneOptions {
  url: string;
  targetPath: string;
  branch?: string;
  username?: string;
  password?: string;
  bearerToken?: string;
  caFile?: string;
  onProgress?: (progress: Git2Progress) => void;
}

export interface Git2RepositoryState {
  branch: string;
  head: string;
  clean: boolean;
  statusEntryCount: number;
  packFileCount: number;
  aheadCount: number;
  behindCount: number;
}

export interface Git2ActionOptions {
  operation: 'stage' | 'commit' | 'fetch' | 'push';
  repositoryPath: string;
  username?: string;
  password?: string;
  bearerToken?: string;
  caFile?: string;
  message?: string;
  authorName?: string;
  authorEmail?: string;
  onProgress?: (progress: Git2Progress) => void;
}

declare const nativeGit2: {
  getVersion(): string;
  getFeatures(): Git2Features;
  getRepositoryState(path: string): Git2RepositoryState;
  clone(options: Git2CloneOptions): Promise<string>;
  gitAction(options: Git2ActionOptions): Promise<string>;
};

export default nativeGit2;
