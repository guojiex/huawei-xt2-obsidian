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
  operation?: 'fetch' | 'push';
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
  trackingKnown: boolean;
  aheadCount: number;
  behindCount: number;
  changes: Git2FileChange[];
}

export interface Git2FileChange {
  path: string;
  status: 'M' | 'A' | 'D';
}

export interface Git2ActionOptions {
  operation: 'stage' | 'commit' | 'fetch' | 'push' | 'pull';
  repositoryPath: string;
  targetBranch?: string;
  username?: string;
  password?: string;
  bearerToken?: string;
  caFile?: string;
  message?: string;
  authorName?: string;
  authorEmail?: string;
  onProgress?: (progress: Git2Progress) => void;
}

export interface Git2DiffLine {
  origin: '+' | '-' | ' ';
  oldLine: number;
  newLine: number;
  text: string;
}

export interface Git2FileDiff {
  path: string;
  status: 'M' | 'A' | 'D';
  lines: Git2DiffLine[];
  truncated: boolean;
}

export interface Git2FileDiffs {
  files: Git2FileDiff[];
  truncatedFiles: number;
}

export interface Git2DiffOptions {
  maxFiles?: number;
  maxBytes?: number;
  maxLines?: number;
}

declare const nativeGit2: {
  getVersion(): string;
  getFeatures(): Git2Features;
  getRepositoryState(path: string, targetBranch?: string): Git2RepositoryState;
  getFileDiffs(path: string, options?: Git2DiffOptions): Git2FileDiffs;
  clone(options: Git2CloneOptions): Promise<string>;
  cancelClone(): void;
  gitAction(options: Git2ActionOptions): Promise<string>;
};

export default nativeGit2;
