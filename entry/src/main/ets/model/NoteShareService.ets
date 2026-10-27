import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { VaultRegistry } from './VaultRegistry';

export interface MarkdownImageReference {
  source: string;
  sourceStart: number;
  sourceEnd: number;
  rootRelative?: boolean;
}

export interface PreparedNoteShare {
  filePath: string;
  fileName: string;
  format: string;
  imageCount: number;
}

interface ResolvedImage {
  sourcePath: string;
  sharePath: string;
}

/** 单篇分享快照：无本地图片输出 MD，有本地图片输出含引用图片的 ZIP。 */
export class NoteShareService {
  private static nextId: number = 0;
  static readonly TEMP_RETENTION_MS: number = 24 * 60 * 60 * 1000;

  static scanMarkdownImages(markdown: string): MarkdownImageReference[] {
    const refs: MarkdownImageReference[] = [];
    let i: number = 0;
    let fenceChar: string = '';
    let fenceLength: number = 0;
    let atLineStart: boolean = true;
    while (i < markdown.length) {
      if (atLineStart) {
        let markerAt: number = i;
        let indent: number = 0;
        while (markerAt < markdown.length && markdown[markerAt] === ' ' && indent < 4) {
          markerAt++;
          indent++;
        }
        if (indent <= 3 && markerAt < markdown.length &&
          (markdown[markerAt] === '`' || markdown[markerAt] === '~')) {
          const marker: string = markdown[markerAt];
          let runEnd: number = markerAt;
          while (runEnd < markdown.length && markdown[runEnd] === marker) {
            runEnd++;
          }
          const runLength: number = runEnd - markerAt;
          if (runLength >= 3) {
            if (fenceChar.length === 0) {
              fenceChar = marker;
              fenceLength = runLength;
            } else if (marker === fenceChar && runLength >= fenceLength) {
              fenceChar = '';
              fenceLength = 0;
            }
            i = NoteShareService.afterLine(markdown, i);
            atLineStart = true;
            continue;
          }
        }
      }
      if (fenceChar.length > 0) {
        i = NoteShareService.afterLine(markdown, i);
        atLineStart = true;
        continue;
      }
      const ch: string = markdown[i];
      if (ch === '<' && markdown.substring(i, i + 4) === '<!--') {
        const commentEnd: number = markdown.indexOf('-->', i + 4);
        i = commentEnd >= 0 ? commentEnd + 3 : markdown.length;
        atLineStart = i > 0 && markdown[i - 1] === '\n';
        continue;
      }
      if (ch === '<' && NoteShareService.isHtmlImageTag(markdown, i)) {
        const tagEnd: number = NoteShareService.findHtmlTagEnd(markdown, i + 4);
        if (tagEnd >= 0) {
          const htmlRef: MarkdownImageReference | null = NoteShareService.htmlImageSource(markdown, i + 4,
            tagEnd);
          if (htmlRef !== null) {
            refs.push(htmlRef);
          }
          i = tagEnd + 1;
          atLineStart = i > 0 && markdown[i - 1] === '\n';
          continue;
        }
      }
      if (ch === '`') {
        let ticksEnd: number = i;
        while (ticksEnd < markdown.length && markdown[ticksEnd] === '`') {
          ticksEnd++;
        }
        const ticks: number = ticksEnd - i;
        let closeAt: number = ticksEnd;
        let foundClose: boolean = false;
        while (closeAt < markdown.length) {
          if (markdown[closeAt] === '`') {
            let closeEnd: number = closeAt;
            while (closeEnd < markdown.length && markdown[closeEnd] === '`') {
              closeEnd++;
            }
            if (closeEnd - closeAt === ticks) {
              i = closeEnd;
              foundClose = true;
              break;
            }
            closeAt = closeEnd;
          } else {
            closeAt++;
          }
        }
        if (foundClose) {
          atLineStart = i > 0 && markdown[i - 1] === '\n';
          continue;
        }
        i = ticksEnd;
        atLineStart = false;
        continue;
      }
      if (ch === '!' && i + 1 < markdown.length && markdown[i + 1] === '[' &&
        !NoteShareService.isEscaped(markdown, i)) {
        if (i + 2 < markdown.length && markdown[i + 2] === '[') {
          const closeAt: number = markdown.indexOf(']]', i + 3);
          if (closeAt >= 0) {
            const aliasAt: number = markdown.indexOf('|', i + 3);
            const targetLimit: number = aliasAt >= 0 && aliasAt < closeAt ? aliasAt : closeAt;
            let sourceStart: number = i + 3;
            let sourceEnd: number = targetLimit;
            while (sourceStart < sourceEnd && /\s/.test(markdown[sourceStart])) {
              sourceStart++;
            }
            while (sourceEnd > sourceStart && /\s/.test(markdown[sourceEnd - 1])) {
              sourceEnd--;
            }
            const source: string = markdown.substring(sourceStart, sourceEnd);
            if (source.length > 0 && NoteShareService.isWikiImagePath(source)) {
              refs.push({ source: source, sourceStart: sourceStart, sourceEnd: sourceEnd, rootRelative: true });
            }
            i = closeAt + 2;
            atLineStart = i > 0 && markdown[i - 1] === '\n';
            continue;
          }
        }
        const altEnd: number = NoteShareService.findUnescaped(markdown, i + 2, ']');
        if (altEnd >= 0 && altEnd + 1 < markdown.length && markdown[altEnd + 1] === '(') {
          const closeParen: number = NoteShareService.findClosingParen(markdown, altEnd + 1);
          if (closeParen >= 0) {
            let sourceStart: number = altEnd + 2;
            while (sourceStart < closeParen && /\s/.test(markdown[sourceStart])) {
              sourceStart++;
            }
            let wrapped: boolean = false;
            if (sourceStart < closeParen && markdown[sourceStart] === '<') {
              sourceStart++;
              wrapped = true;
            }
            const sourceEnd: number = NoteShareService.findImageSourceEnd(markdown, sourceStart, closeParen,
              wrapped);
            if (sourceEnd > sourceStart) {
              refs.push({
                source: markdown.substring(sourceStart, sourceEnd),
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
              });
              i = closeParen + 1;
              atLineStart = i > 0 && markdown[i - 1] === '\n';
              continue;
            }
          }
        }
      }
      atLineStart = ch === '\n';
      i++;
    }
    return refs;
  }

  /** Markdown/HTML 图片按 noteDir 解析；Obsidian 图片嵌入按库根解析；均拒绝越出库根。 */
  static resolveImagePath(notePath: string, source: string, rootRelative: boolean = false): string {
    if (source.length === 0 || source.startsWith('/') || source.indexOf('\\') >= 0) {
      throw new Error('图片路径必须是当前知识库内的相对路径：' + source);
    }
    let decoded: string = source;
    try {
      decoded = decodeURIComponent(source);
    } catch (error) {
      decoded = source;
    }
    const slash: number = notePath.lastIndexOf('/');
    const noteDir: string = slash >= 0 ? notePath.substring(0, slash) : '';
    const base: string = !rootRelative && noteDir.length > 0 ? noteDir + '/' + decoded : decoded;
    const segments: string[] = [];
    const parts: string[] = base.split('/');
    for (let i = 0; i < parts.length; i++) {
      const segment: string = parts[i];
      if (segment.length === 0 || segment === '.') {
        continue;
      }
      if (segment === '..') {
        if (segments.length === 0) {
          throw new Error('图片路径越出当前知识库：' + source);
        }
        segments.pop();
        continue;
      }
      if (segment.startsWith('.')) {
        throw new Error('不允许引用知识库内部目录：' + source);
      }
      segments.push(segment);
    }
    if (segments.length === 0) {
      throw new Error('图片路径不能为空：' + source);
    }
    return segments.join('/');
  }

  /** Obsidian ![[...]] 中，仅把带常见图片扩展名的 vault-root 目标作为图片收集。 */
  private static isWikiImagePath(source: string): boolean {
    const path: string = source.split(/[?#]/)[0];
    return /\.(?:png|jpe?g|gif|webp|svg|bmp)$/i.test(path);
  }

  /** HTTP(S)、data/blob 与协议相对图片均保留为原链接，不作为库内文件读取。 */
  static isRemoteImage(source: string): boolean {
    return source.startsWith('//') || /^(https?:|data:|blob:)/i.test(source);
  }

  /** ZIP 路径中不分享应用内部状态、Git 元数据、草稿、缓存和常见凭据文件。 */
  static isExcludedVaultPath(relativePath: string): boolean {
    const parts: string[] = relativePath.split('/');
    for (let i = 0; i < parts.length; i++) {
      const segment: string = parts[i].toLowerCase();
      if (segment.startsWith('.') || segment === 'drafts' || segment === 'cache' || segment === 'caches' ||
        segment === 'node_modules' || segment === 'credentials' || segment === 'tokens' || segment === 'secrets') {
        return true;
      }
      if (segment === '.env' || segment.startsWith('.env.') || segment === 'credentials.json' ||
        segment === 'token.json' || segment === 'tokens.json' || segment === 'id_rsa' || segment === 'id_ed25519' ||
        segment.endsWith('.pem') || segment.endsWith('.p12') || segment.endsWith('.pfx')) {
        return true;
      }
    }
    return false;
  }

  /** Markdown 图片路径采用 URL 编码，斜线保留为目录分隔符。 */
  static encodeRelativePath(path: string): string {
    const parts: string[] = path.split('/');
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] !== '..' && parts[i] !== '.') {
        parts[i] = encodeURIComponent(parts[i]);
      }
    }
    return parts.join('/');
  }

  /** 按归档路径重写图片引用；调用方先确认每个本地引用均有对应资源。 */
  static rewriteMarkdownImages(markdown: string, notePath: string, archiveImages: Map<string, string>): string {
    const references: MarkdownImageReference[] = NoteShareService.scanMarkdownImages(markdown);
    let rewritten: string = markdown;
    for (let i = references.length - 1; i >= 0; i--) {
      const ref: MarkdownImageReference = references[i];
      if (NoteShareService.isRemoteImage(ref.source)) {
        continue;
      }
      const sourcePath: string = NoteShareService.resolveImagePath(notePath, ref.source, ref.rootRelative === true);
      const archivePath: string | undefined = archiveImages.get(sourcePath);
      if (archivePath === undefined) {
        throw new Error('缺少本地图片，未生成分享文件：' + ref.source);
      }
      const relativeAsset: string = ref.rootRelative === true ? archivePath :
        NoteShareService.relativePath(NoteShareService.parentOf(notePath), archivePath);
      rewritten = rewritten.substring(0, ref.sourceStart) + NoteShareService.encodeRelativePath(relativeAsset) +
        rewritten.substring(ref.sourceEnd);
    }
    return rewritten;
  }

  static async prepareNote(registry: VaultRegistry, vaultId: string, notePath: string,
    markdownSnapshot: string): Promise<PreparedNoteShare> {
    NoteShareService.pruneExpired(registry);
    const references: MarkdownImageReference[] = NoteShareService.scanMarkdownImages(markdownSnapshot);
    const resolved: ResolvedImage[] = [];
    const missing: string[] = [];
    for (let i = 0; i < references.length; i++) {
      const ref: MarkdownImageReference = references[i];
      if (NoteShareService.isRemoteImage(ref.source)) {
        continue;
      }
      let sourcePath: string = '';
      try {
        sourcePath = NoteShareService.resolveImagePath(notePath, ref.source, ref.rootRelative === true);
      } catch (error) {
        if (missing.indexOf(ref.source) < 0) {
          missing.push(ref.source);
        }
        continue;
      }
      let exists: boolean = false;
      try {
        const imageStat: fileIo.Stat = fileIo.lstatSync(registry.absoluteIn(vaultId, sourcePath));
        exists = imageStat.isFile() && !imageStat.isSymbolicLink();
      } catch (error) {
        exists = false;
      }
      if (!exists) {
        if (missing.indexOf(ref.source) < 0) {
          missing.push(ref.source);
        }
        continue;
      }
      if (NoteShareService.findResolved(resolved, sourcePath) < 0) {
        resolved.push({ sourcePath: sourcePath, sharePath: '' });
      }
    }
    if (missing.length > 0) {
      throw new Error('缺少本地图片，未生成分享文件：' + missing.join('、'));
    }

    const shareId: string = 'note-' + Date.now().toString() + '-' + NoteShareService.nextId.toString();
    NoteShareService.nextId++;
    const shareDir: string = registry.sharePath(shareId);
    fileIo.mkdirSync(shareDir, true);
    const noteName: string = notePath.substring(notePath.lastIndexOf('/') + 1);
    if (resolved.length === 0) {
      try {
        const outputPath: string = registry.sharePath(shareId + '/' + noteName);
        await NoteShareService.writeAtomic(outputPath, markdownSnapshot);
        return { filePath: outputPath, fileName: noteName, format: 'Markdown', imageCount: 0 };
      } catch (error) {
        NoteShareService.removeTree(registry, shareId);
        const err = error as Error;
        throw new Error(err.message);
      }
    }

    const payloadDir: string = registry.sharePath(shareId + '/payload');
    fileIo.mkdirSync(payloadDir, true);
    try {
      const noteParent: string = NoteShareService.parentOf(notePath);
      if (noteParent.length > 0) {
        fileIo.mkdirSync(registry.sharePath(shareId + '/payload/' + noteParent), true);
      }
      const imageDir: string = registry.sharePath(shareId + '/payload/assets');
      fileIo.mkdirSync(imageDir, true);
      const archiveImages: Map<string, string> = new Map<string, string>();
      for (let i = 0; i < resolved.length; i++) {
        const ext: string = NoteShareService.safeExtension(resolved[i].sourcePath);
        const assetPath: string = 'assets/share-image-' + (i + 1).toString() + ext;
        resolved[i].sharePath = assetPath;
        archiveImages.set(resolved[i].sourcePath, assetPath);
        fileIo.copyFileSync(registry.absoluteIn(vaultId, resolved[i].sourcePath),
          registry.sharePath(shareId + '/payload/' + assetPath));
      }
      const packagedMarkdown: string = NoteShareService.rewriteMarkdownImages(markdownSnapshot, notePath,
        archiveImages);
      const packagedNote: string = registry.sharePath(shareId + '/payload/' + notePath);
      await NoteShareService.writeAtomic(packagedNote, packagedMarkdown);
      const stem: string = noteName.toLowerCase().endsWith('.md')
        ? noteName.substring(0, noteName.length - 3) : noteName;
      const zipName: string = stem + '.zip';
      const zipPath: string = registry.sharePath(shareId + '/' + zipName);
      await zlib.compressFile(payloadDir, zipPath, {});
      NoteShareService.removeTree(registry, shareId + '/payload');
      return { filePath: zipPath, fileName: zipName, format: 'ZIP', imageCount: resolved.length };
    } catch (error) {
      try {
        NoteShareService.removeTree(registry, shareId);
      } catch (cleanupError) {
        // The session directory contains only files created by this failed preparation.
      }
      const err = error as Error;
      throw new Error('生成分享文件失败，请检查本地空间后重试：' + err.message);
    }
  }

  /** 递归清理本服务创建的临时目录；CoreFileKit 的 rmdirSync 仅能删除空目录。 */
  static removeTree(registry: VaultRegistry, relativePath: string): void {
    const path: string = registry.sharePath(relativePath);
    try {
      if (!fileIo.accessSync(path)) {
        return;
      }
    } catch (error) {
      return;
    }
    const stat: fileIo.Stat = fileIo.lstatSync(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) {
      fileIo.unlinkSync(path);
      return;
    }
    const children: string[] = fileIo.listFileSync(path);
    for (let i = 0; i < children.length; i++) {
      NoteShareService.removeTree(registry, relativePath + '/' + children[i]);
    }
    fileIo.rmdirSync(path);
  }

  private static findResolved(images: ResolvedImage[], sourcePath: string): number {
    for (let i = 0; i < images.length; i++) {
      if (images[i].sourcePath === sourcePath) {
        return i;
      }
    }
    return -1;
  }

  static parentOf(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  static relativePath(fromDir: string, toPath: string): string {
    const fromParts: string[] = fromDir.length > 0 ? fromDir.split('/') : [];
    const toParts: string[] = toPath.split('/');
    let common: number = 0;
    while (common < fromParts.length && common < toParts.length && fromParts[common] === toParts[common]) {
      common++;
    }
    const out: string[] = [];
    for (let i = common; i < fromParts.length; i++) {
      out.push('..');
    }
    for (let i = common; i < toParts.length; i++) {
      out.push(toParts[i]);
    }
    return out.join('/');
  }

  private static safeExtension(path: string): string {
    const slash: number = path.lastIndexOf('/');
    const dot: number = path.lastIndexOf('.');
    if (dot <= slash || dot === path.length - 1) {
      return '.img';
    }
    const ext: string = path.substring(dot);
    return /^\.[A-Za-z0-9]{1,10}$/.test(ext) ? ext : '.img';
  }

  private static afterLine(text: string, from: number): number {
    const newline: number = text.indexOf('\n', from);
    return newline < 0 ? text.length : newline + 1;
  }

  private static isEscaped(text: string, at: number): boolean {
    let slashes: number = 0;
    for (let i = at - 1; i >= 0 && text[i] === '\\'; i--) {
      slashes++;
    }
    return slashes % 2 === 1;
  }

  private static findUnescaped(text: string, from: number, target: string): number {
    for (let i = from; i < text.length; i++) {
      if (text[i] === target && !NoteShareService.isEscaped(text, i)) {
        return i;
      }
    }
    return -1;
  }

  private static findClosingParen(text: string, openAt: number): number {
    let depth: number = 0;
    for (let i = openAt; i < text.length; i++) {
      if (NoteShareService.isEscaped(text, i)) {
        continue;
      }
      if (text[i] === '(') {
        depth++;
      } else if (text[i] === ')') {
        depth--;
        if (depth === 0) {
          return i;
        }
      }
    }
    return -1;
  }

  private static findImageSourceEnd(text: string, start: number, closeParen: number, wrapped: boolean): number {
    if (wrapped) {
      const closeAngle: number = NoteShareService.findUnescaped(text, start, '>');
      return closeAngle > start && closeAngle < closeParen ? closeAngle : -1;
    }
    let nested: number = 0;
    for (let i = start; i < closeParen; i++) {
      if (NoteShareService.isEscaped(text, i)) {
        continue;
      }
      if (text[i] === '(') {
        nested++;
      } else if (text[i] === ')' && nested > 0) {
        nested--;
      } else if (/\s/.test(text[i]) && nested === 0) {
        return i;
      }
    }
    return closeParen;
  }

  private static isHtmlImageTag(text: string, start: number): boolean {
    if (start + 4 > text.length || text.substring(start, start + 4).toLowerCase() !== '<img') {
      return false;
    }
    const boundary: string = text[start + 4];
    return boundary === '>' || boundary === '/' || /\s/.test(boundary);
  }

  private static findHtmlTagEnd(text: string, from: number): number {
    let quote: string = '';
    for (let i = from; i < text.length; i++) {
      const ch: string = text[i];
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
      } else if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '>') {
        return i;
      }
    }
    return -1;
  }

  private static htmlImageSource(text: string, from: number, tagEnd: number): MarkdownImageReference | null {
    let i: number = from;
    while (i < tagEnd) {
      while (i < tagEnd && /\s/.test(text[i])) {
        i++;
      }
      if (i >= tagEnd || text[i] === '/') {
        return null;
      }
      const nameStart: number = i;
      while (i < tagEnd && !/[\s=/>]/.test(text[i])) {
        i++;
      }
      if (i === nameStart) {
        i++;
        continue;
      }
      const attributeName: string = text.substring(nameStart, i).toLowerCase();
      while (i < tagEnd && /\s/.test(text[i])) {
        i++;
      }
      if (i >= tagEnd || text[i] !== '=') {
        continue;
      }
      i++;
      while (i < tagEnd && /\s/.test(text[i])) {
        i++;
      }
      if (i >= tagEnd) {
        return null;
      }
      let sourceStart: number = i;
      let sourceEnd: number = i;
      const quote: string = text[i];
      if (quote === '"' || quote === "'") {
        sourceStart = i + 1;
        sourceEnd = text.indexOf(quote, sourceStart);
        if (sourceEnd < 0 || sourceEnd > tagEnd) {
          return null;
        }
        i = sourceEnd + 1;
      } else {
        while (i < tagEnd && !/\s/.test(text[i])) {
          i++;
        }
        sourceEnd = i;
      }
      if (attributeName === 'src' && sourceEnd > sourceStart) {
        const source: string = text.substring(sourceStart, sourceEnd).replace(/&amp;/g, '&');
        return { source: source, sourceStart: sourceStart, sourceEnd: sourceEnd };
      }
    }
    return null;
  }

  static writeAtomic(path: string, content: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(path);
      let settled: boolean = false;
      let timerId: number = -1;
      const fail = (message: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (error) {
          // Preserve the original write failure.
        }
        reject(new Error(message));
      };
      const commit = (): void => {
        if (settled) {
          return;
        }
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.finishWrite();
        } catch (error) {
          const err = error as BusinessError;
          fail(err.message);
          return;
        }
        settled = true;
        resolve();
      };
      try {
        const stream: fileIo.WriteStream = atomicFile.startWrite();
        timerId = setTimeout((): void => { fail('AtomicFile write 回调超时'); }, 3000);
        if (content.length === 0) {
          commit();
        } else {
          stream.write(content, 'utf-8', (err?: BusinessError): void => {
            if (err !== undefined && err !== null) {
              fail(err.message);
              return;
            }
            commit();
          });
        }
      } catch (error) {
        const err = error as BusinessError;
        fail(err.message);
      }
    });
  }

  /** 分享产物只留在 App cacheDir；下次分享时清理本服务超过 24 小时的临时目录。 */
  static pruneExpired(registry: VaultRegistry, now: number = Date.now()): void {
    const root: string = registry.sharePath('');
    try {
      if (!fileIo.accessSync(root)) {
        return;
      }
    } catch (error) {
      return;
    }
    const children: string[] = fileIo.listFileSync(root);
    for (let i = 0; i < children.length; i++) {
      const name: string = children[i];
      const firstDash: number = name.indexOf('-');
      const lastDash: number = name.lastIndexOf('-');
      if (firstDash < 0 || firstDash === lastDash || lastDash >= name.length - 1) {
        continue;
      }
      const kind: string = name.substring(0, firstDash);
      const timestamp: string = name.substring(firstDash + 1, lastDash);
      const serial: string = name.substring(lastDash + 1);
      if ((kind !== 'note' && kind !== 'archive' && kind !== 'image') ||
        !NoteShareService.isDigits(timestamp) || !NoteShareService.isDigits(serial) ||
        !fileIo.statSync(registry.sharePath(name)).isDirectory()) {
        continue;
      }
      const createdAt: number = Number(timestamp);
      if (createdAt > 0 && now - createdAt >= NoteShareService.TEMP_RETENTION_MS) {
        NoteShareService.removeTree(registry, name);
      }
    }
  }

  private static isDigits(value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    for (let i = 0; i < value.length; i++) {
      if (value[i] < '0' || value[i] > '9') {
        return false;
      }
    }
    return true;
  }
}
