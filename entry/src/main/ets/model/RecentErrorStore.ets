import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type RecentErrorOperation =
  'startup' | 'workspace' | 'note' | 'editor_preview' | 'vault' | 'file' |
  'authorization' | 'git_import' | 'git_sync' | 'share' | 'settings';

export type RecentErrorPhase =
  'restore' | 'read' | 'save' | 'switch' | 'bridge' | 'permission' | 'create' |
  'rename' | 'delete' | 'move' | 'restore_trash' | 'search' | 'clone' | 'commit' |
  'fetch' | 'push' | 'prepare' | 'handoff' | 'reset' | 'build_commit_copy' |
  'recent_errors_copy';

export type RecentErrorCategory =
  'storage_failure' | 'bridge_timeout' | 'permission_failure' | 'network_failure' |
  'conflict' | 'clipboard_failure' | 'unknown';

export type RecentErrorOutcome =
  'not_completed' | 'partially_completed' | 'completed_with_warning' | 'status_unknown';

export type RecentErrorNextStep =
  'retry' | 'reopen_note' | 'restore_permission' | 'check_network' | 'check_status';

export interface RecentErrorRecord {
  timestamp: number;
  operation: RecentErrorOperation;
  phase: RecentErrorPhase;
  category: RecentErrorCategory;
  outcome: RecentErrorOutcome;
  nextStep: RecentErrorNextStep;
}

export interface RecentErrorSnapshot {
  schemaVersion: number;
  records: RecentErrorRecord[];
}

const OPERATION_VALUES: string[] = [
  'startup', 'workspace', 'note', 'editor_preview', 'vault', 'file', 'authorization',
  'git_import', 'git_sync', 'share', 'settings'
];
const PHASE_VALUES: string[] = [
  'restore', 'read', 'save', 'switch', 'bridge', 'permission', 'create', 'rename', 'delete',
  'move', 'restore_trash', 'search', 'clone', 'commit', 'fetch', 'push', 'prepare', 'handoff',
  'reset', 'build_commit_copy', 'recent_errors_copy'
];
const CATEGORY_VALUES: string[] = [
  'storage_failure', 'bridge_timeout', 'permission_failure', 'network_failure', 'conflict',
  'clipboard_failure', 'unknown'
];
const OUTCOME_VALUES: string[] = [
  'not_completed', 'partially_completed', 'completed_with_warning', 'status_unknown'
];
const NEXT_STEP_VALUES: string[] = [
  'retry', 'reopen_note', 'restore_permission', 'check_network', 'check_status'
];

export class RecentErrorStore {
  static readonly LIMIT: number = 20;
  static readonly MAX_SERIALIZED_LENGTH: number = 8192;
  private static readonly PREF_NAME: string = 'recent_error_diagnostics';
  private static readonly PREF_KEY: string = 'latest';
  private store: preferences.Preferences | null = null;
  private available: boolean = false;

  constructor(context: common.UIAbilityContext, store?: preferences.Preferences) {
    try {
      this.store = store ?? preferences.getPreferencesSync(context, { name: RecentErrorStore.PREF_NAME });
      this.available = true;
    } catch (error) {
      this.available = false;
    }
  }

  isAvailable(): boolean {
    return this.available && this.store !== null;
  }

  load(): RecentErrorRecord[] | null {
    if (this.store === null) {
      this.available = false;
      return null;
    }
    try {
      const raw: string = this.store.getSync(RecentErrorStore.PREF_KEY, '') as string;
      const snapshot: RecentErrorSnapshot | null = parseRecentErrorSnapshot(raw);
      if (snapshot === null) {
        this.available = false;
        return null;
      }
      this.available = true;
      return snapshot.records;
    } catch (error) {
      this.available = false;
      return null;
    }
  }

  recordFailure(operation: RecentErrorOperation, phase: RecentErrorPhase, category: RecentErrorCategory,
    outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep): boolean {
    const current: RecentErrorRecord[] | null = this.load();
    if (current === null) {
      return false;
    }
    const next: RecentErrorRecord[] = [{
      timestamp: Date.now(),
      operation: operation,
      phase: phase,
      category: category,
      outcome: outcome,
      nextStep: nextStep
    }];
    for (let i: number = 0; i < current.length && next.length < RecentErrorStore.LIMIT; i++) {
      next.push(current[i]);
    }
    return this.persist(next);
  }

  private persist(records: RecentErrorRecord[]): boolean {
    if (this.store === null) {
      this.available = false;
      return false;
    }
    const raw: string = serializeRecentErrorSnapshot(records);
    if (raw.length === 0 || raw.length > RecentErrorStore.MAX_SERIALIZED_LENGTH) {
      this.available = false;
      return false;
    }
    try {
      this.store.putSync(RecentErrorStore.PREF_KEY, raw);
      this.store.flushSync();
      this.available = true;
      return true;
    } catch (error) {
      this.available = false;
      return false;
    }
  }
}

export function parseRecentErrorSnapshot(raw: string): RecentErrorSnapshot | null {
  if (raw.length === 0) {
    return { schemaVersion: 1, records: [] };
  }
  if (raw.length > RecentErrorStore.MAX_SERIALIZED_LENGTH) {
    return null;
  }
  try {
    const value: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    if (value['schemaVersion'] !== 1 || !Array.isArray(value['records'])) {
      return null;
    }
    const source: Object[] = value['records'] as Object[];
    const records: RecentErrorRecord[] = [];
    for (let i: number = 0; i < source.length && records.length < RecentErrorStore.LIMIT; i++) {
      const record: RecentErrorRecord | null = parseRecentErrorRecord(source[i]);
      if (record === null) {
        return null;
      }
      records.push(record);
    }
    return { schemaVersion: 1, records: records };
  } catch (error) {
    return null;
  }
}

export function serializeRecentErrorSnapshot(records: RecentErrorRecord[]): string {
  const bounded: RecentErrorRecord[] = [];
  for (let i: number = 0; i < records.length && bounded.length < RecentErrorStore.LIMIT; i++) {
    const record: RecentErrorRecord | null = parseRecentErrorRecord(records[i] as Object);
    if (record === null) {
      return '';
    }
    bounded.push(record);
  }
  const snapshot: RecentErrorSnapshot = { schemaVersion: 1, records: bounded };
  const raw: string = JSON.stringify(snapshot);
  return raw.length <= RecentErrorStore.MAX_SERIALIZED_LENGTH ? raw : '';
}

export function formatRecentError(record: RecentErrorRecord): string {
  const safeRecord: RecentErrorRecord | null = parseRecentErrorRecord(record as Object);
  if (safeRecord === null) {
    return '诊断记录无效';
  }
  const date: string = new Date(safeRecord.timestamp).toLocaleString();
  return date + ' · 操作：' + operationLabel(safeRecord.operation) + ' / ' + phaseLabel(safeRecord.phase) +
    ' · 分类：' + categoryLabel(safeRecord.category) + '\n结果：' + outcomeLabel(safeRecord.outcome) +
    ' · 下一步：' + nextStepLabel(safeRecord.nextStep);
}

export function formatRecentErrorsForCopy(records: RecentErrorRecord[]): string {
  const lines: string[] = [];
  for (let i: number = 0; i < records.length && i < RecentErrorStore.LIMIT; i++) {
    lines.push(formatRecentError(records[i]));
  }
  return lines.join('\n\n');
}

export function formatRecentErrorFeedback(operation: RecentErrorOperation, phase: RecentErrorPhase,
  category: RecentErrorCategory, outcome: RecentErrorOutcome, nextStep: RecentErrorNextStep): string {
  return operationLabel(operation) + ' / ' + phaseLabel(phase) + '失败；' + outcomeLabel(outcome) +
    '；' + categoryLabel(category) + '。下一步：' + nextStepLabel(nextStep) + '。';
}

function parseRecentErrorRecord(value: Object): RecentErrorRecord | null {
  if (value === null || typeof value !== 'object') {
    return null;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  if (typeof record['timestamp'] !== 'number' || !Number.isFinite(record['timestamp'] as number) ||
    (record['timestamp'] as number) <= 0 || !isAllowed(record['operation'], OPERATION_VALUES) ||
    !isAllowed(record['phase'], PHASE_VALUES) || !isAllowed(record['category'], CATEGORY_VALUES) ||
    !isAllowed(record['outcome'], OUTCOME_VALUES) || !isAllowed(record['nextStep'], NEXT_STEP_VALUES)) {
    return null;
  }
  return {
    timestamp: record['timestamp'] as number,
    operation: record['operation'] as RecentErrorOperation,
    phase: record['phase'] as RecentErrorPhase,
    category: record['category'] as RecentErrorCategory,
    outcome: record['outcome'] as RecentErrorOutcome,
    nextStep: record['nextStep'] as RecentErrorNextStep
  };
}

function isAllowed(value: Object, allowed: string[]): boolean {
  return typeof value === 'string' && allowed.indexOf(value as string) >= 0;
}

function operationLabel(value: RecentErrorOperation): string {
  switch (value) {
    case 'startup': return '启动';
    case 'workspace': return '工作区';
    case 'note': return '笔记';
    case 'editor_preview': return '编辑与预览';
    case 'vault': return '知识库';
    case 'file': return '文件';
    case 'authorization': return '目录授权';
    case 'git_import': return 'Git 导入';
    case 'git_sync': return 'Git 同步';
    case 'share': return '分享';
    default: return '设置';
  }
}

function phaseLabel(value: RecentErrorPhase): string {
  switch (value) {
    case 'restore': return '恢复';
    case 'read': return '读取';
    case 'save': return '保存';
    case 'switch': return '切换';
    case 'bridge': return '桥接';
    case 'permission': return '授权';
    case 'create': return '创建';
    case 'rename': return '重命名';
    case 'delete': return '删除';
    case 'move': return '移动';
    case 'restore_trash': return '回收站恢复';
    case 'search': return '搜索';
    case 'clone': return '克隆';
    case 'commit': return '提交';
    case 'fetch': return '获取';
    case 'push': return '推送';
    case 'prepare': return '准备';
    case 'handoff': return '系统交接';
    case 'reset': return '重置';
    case 'build_commit_copy': return '复制构建提交号';
    default: return '复制错误记录';
  }
}

function categoryLabel(value: RecentErrorCategory): string {
  switch (value) {
    case 'storage_failure': return '本地存储失败';
    case 'bridge_timeout': return '桥接超时';
    case 'permission_failure': return '授权失败';
    case 'network_failure': return '网络失败';
    case 'conflict': return '状态冲突';
    case 'clipboard_failure': return '剪贴板失败';
    default: return '原因未确定';
  }
}

function outcomeLabel(value: RecentErrorOutcome): string {
  switch (value) {
    case 'not_completed': return '未完成';
    case 'partially_completed': return '部分完成';
    case 'completed_with_warning': return '已完成但有警告';
    default: return '完成状态未确认';
  }
}

function nextStepLabel(value: RecentErrorNextStep): string {
  switch (value) {
    case 'reopen_note': return '重新打开笔记';
    case 'restore_permission': return '检查目录授权';
    case 'check_network': return '检查网络后重试';
    case 'check_status': return '先检查当前状态';
    default: return '稍后重试';
  }
}
