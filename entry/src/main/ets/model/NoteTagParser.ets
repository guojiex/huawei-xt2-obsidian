/**
 * NoteTagParser.ets —— v2.11 211.2 标签提取纯函数。
 *
 * 口径逐条对齐 v2 原型（docs/prototype/v2/index.html 的 validTag /
 * frontmatterTags / inlineTags / noteTagList）与 mdpreview
 * renderer.mjs 同源规则；三处（原型 / mdpreview / 本文件）语义必须保持一致，
 * 行为级测试见 tools/tests/test_note_tag_filter.mjs。
 *
 * 纯逻辑、零系统依赖（与 SearchStore.ets 同套路），可在 Node 单测里裸跑。
 * 隐私红线（硬约束 16）：本文件不落任何日志，标签值是笔记内容。
 */

/** 笔记切分：前置 YAML frontmatter（含分隔行）与正文。 */
export interface FrontmatterSplit {
  frontmatter: string;
  body: string;
}

/** Leading YAML frontmatter block（BOM / CRLF / `---`·`...` 闭合），与 v2 原型 markdownBody 同规则。 */
const FRONTMATTER_PATTERN: RegExp = /^\uFEFF?---[ \t]*\r?\n(?:[\s\S]*?\r?\n)?(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;

/** 标签合法性（原型 validTag）：字符集合法（含 `.`，版本号类标签）且不能纯数字。 */
export function isValidTag(value: string): boolean {
  return /^[\p{L}\p{N}\p{M}\p{S}_/.-]+$/u.test(value) && /[^\p{N}]/u.test(value);
}

/**
 * 引号内标签值校验（frontmatter 双/单引号值解出后）：字符集在 isValidTag 基础上
 * 放宽空格与撇号（引号内是完整字面量，如 "a b"、'it''s'）；结构性字符（`[]`、
 * 逗号、引号本身等）与纯数字仍然拒绝。裸值不走本函数（211.2）。
 */
function isValidQuotedTag(value: string): boolean {
  return /^[\p{L}\p{N}\p{M}\p{S}_/.' -]+$/u.test(value) && /[^\p{N}]/u.test(value);
}

/** 行内 `[]` 列表元素收集（items 正则与 mdpreview 同源）。 */
function pushInlineItems(values: string[], inline: string): void {
  const items: RegExpMatchArray | null =
    inline.slice(1, -1).match(/"(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^,]+/g);
  if (items !== null) {
    for (let j = 0; j < items.length; j++) {
      values.push(items[j]);
    }
  }
}

/** 切出前置 frontmatter；无 frontmatter 时 frontmatter 为空串、body 为原文。 */
export function splitNoteFrontmatter(markdown: string): FrontmatterSplit {
  const match: RegExpExecArray | null = FRONTMATTER_PATTERN.exec(markdown);
  if (match === null) {
    return { frontmatter: '', body: markdown };
  }
  return { frontmatter: match[0], body: markdown.slice(match[0].length) };
}

/**
 * frontmatter `tags:` 值提取（行内 `[a, b]` / 块列表 / 裸标量 / 双引号 JSON /
 * 单引号 '' 转义 / 行内 `#` 前缀），与 mdpreview renderer.mjs#frontmatterTags
 * 同源规则：按小写去重、保首个书写形式。
 */
export function frontmatterTags(markdown: string): string[] {
  const split: FrontmatterSplit = splitNoteFrontmatter(markdown);
  if (split.frontmatter.length === 0) {
    return [];
  }
  const lines: string[] = split.frontmatter.replace(/^\uFEFF/, '').split(/\r?\n/);
  const values: string[] = [];
  let reading: boolean = false;
  for (let i = 1; i < lines.length - 1; i++) {
    const line: string = lines[i];
    const key: RegExpExecArray | null = /^tags:[ \t]*(.*)$/.exec(line);
    if (key !== null) {
      reading = true;
      const inline: string = key[1].trim();
      if (inline.startsWith('[') && inline.endsWith(']')) {
        // 原样收列表：行内 `#前缀` 元素不被行尾注释剥离误砍
        pushInlineItems(values, inline);
      } else {
        const stripped: string = inline.replace(/[ \t]+#.*$/, '').trim();
        if (stripped.startsWith('[') && stripped.endsWith(']')) {
          pushInlineItems(values, stripped);
        } else if (stripped.length > 0) {
          // 裸标量（`tags: foo`）同样识别（211.2）
          values.push(stripped);
        }
      }
      continue;
    }
    if (reading) {
      const item: RegExpExecArray | null = /^[ \t]*-[ \t]+(.*)$/.exec(line);
      if (item !== null) {
        values.push(item[1]);
      } else if (/^[^ \t#]/.test(line)) {
        reading = false;
      }
    }
  }
  const tags: string[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < values.length; i++) {
    let value: string = values[i].trim();
    let quoted: boolean = false;
    if (value.startsWith('"') && value.endsWith('"')) {
      // JSON 字符串解引号；解析失败跳过该值
      quoted = true;
      try {
        const parsed: string = JSON.parse(value) as string;
        value = parsed;
      } catch (_error) {
        continue;
      }
    } else if (value.startsWith("'") && value.endsWith("'")) {
      quoted = true;
      value = value.slice(1, -1).replace(/''/g, "'");
    } else {
      value = value.replace(/[ \t]+#.*$/, '');
    }
    value = value.replace(/^#/, '');
    const valid: boolean = quoted ? isValidQuotedTag(value) : isValidTag(value);
    if (valid && !seen.has(value.toLowerCase())) {
      seen.add(value.toLowerCase());
      tags.push(value);
    }
  }
  return tags;
}

/**
 * 正文行内 `#tag` 提取（原型 inlineTags）：剥离 fenced code、行内 code、
 * `$$…$$`、`$…$`（替换为空格）后匹配 `(^|[\s(（])#([\p{L}\p{N}\p{M}\p{S}_/-]+)`；
 * 按小写去重、保首个书写形式、跳过纯数字。
 */
export function inlineTags(markdown: string): string[] {
  const split: FrontmatterSplit = splitNoteFrontmatter(markdown);
  const stripped: string = split.body
    .replace(/```[\s\S]*?(```|$)/g, ' ')
    .replace(/`[^`\n]*`/g, ' ')
    .replace(/\$\$[\s\S]*?\$\$/g, ' ')
    .replace(/\$[^$\n]+\$/g, ' ');
  const found: string[] = [];
  const seen: Set<string> = new Set<string>();
  const pattern: RegExp = /(^|[\s(（])#([\p{L}\p{N}\p{M}\p{S}_/-]+)/gu;
  let match: RegExpExecArray | null = pattern.exec(stripped);
  while (match !== null) {
    const value: string = match[2];
    if (isValidTag(value)) {
      const key: string = value.toLowerCase();
      if (!seen.has(key)) {
        seen.add(key);
        found.push(value);
      }
    }
    match = pattern.exec(stripped);
  }
  return found;
}

/**
 * 单笔记标签全集（原型 noteTagList）：frontmatter 优先于行内，
 * 按小写去重、保首个书写形式。产物即 search_tags 的写入载荷。
 */
export function noteTagList(markdown: string): string[] {
  const tags: string[] = [];
  const seen: Set<string> = new Set<string>();
  const parts: string[] = frontmatterTags(markdown).concat(inlineTags(markdown));
  for (let i = 0; i < parts.length; i++) {
    const key: string = parts[i].toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      tags.push(parts[i]);
    }
  }
  return tags;
}
