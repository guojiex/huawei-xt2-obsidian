export interface GitBranchNameValidation {
  valid: boolean;
  reason: string;
}

export function validateGitBranchName(branch: string): GitBranchNameValidation {
  if (branch.length === 0) {
    return { valid: false, reason: '分支名不能为空' };
  }
  let characterCount: number = 0;
  for (let i: number = 0; i < branch.length; i++) {
    const code: number = branch.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < branch.length) {
      const next: number = branch.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        i++;
      }
    }
    characterCount++;
  }
  if (characterCount > 100) {
    return { valid: false, reason: '分支名不能超过 100 个字符' };
  }
  if (branch === 'HEAD') {
    return { valid: false, reason: '分支名不能是 HEAD' };
  }
  if (branch.charAt(0) === '/' || branch.charAt(0) === '.' || branch.charAt(0) === '-') {
    return { valid: false, reason: '分支名不能以 /、. 或 - 开头' };
  }
  if (branch.endsWith('/') || branch.endsWith('.')) {
    return { valid: false, reason: '分支名不能以 / 或 . 结尾' };
  }
  if (branch.endsWith('.lock')) {
    return { valid: false, reason: '分支名不能以 .lock 结尾' };
  }
  if (branch.indexOf('..') >= 0) {
    return { valid: false, reason: '分支名不能包含 ..' };
  }
  if (branch.indexOf('@{') >= 0) {
    return { valid: false, reason: '分支名不能包含 @{' };
  }
  if (branch.indexOf('//') >= 0) {
    return { valid: false, reason: '分支名不能包含连续斜线' };
  }
  if (branch === '@') {
    return { valid: false, reason: '分支名不能是 @' };
  }
  for (let i = 0; i < branch.length; i++) {
    const code: number = branch.charCodeAt(i);
    const ch: string = branch.charAt(i);
    if (code <= 0x20 || code === 0x7f || ch === '~' || ch === '^' || ch === ':' ||
      ch === '?' || ch === '*' || ch === '[' || ch === '\\') {
      return { valid: false, reason: '分支名含有 Git 不允许的字符' };
    }
  }
  const components: string[] = branch.split('/');
  for (let i = 0; i < components.length; i++) {
    if (components[i].length === 0 || components[i].charAt(0) === '.' ||
      components[i].endsWith('.lock')) {
      return { valid: false, reason: '分支名的路径段不符合 Git 引用规则' };
    }
  }
  return { valid: true, reason: '' };
}
