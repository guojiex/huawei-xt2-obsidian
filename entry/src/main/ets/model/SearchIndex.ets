/** Current-vault full-text index. It stores only character grams and paths, never note bodies. */
export interface FullTextSearchResult {
  path: string;
  excerpt: string;
}

export class SearchIndex {
  private documentTerms: Map<string, string[]> = new Map<string, string[]>();
  private postings: Map<string, string[]> = new Map<string, string[]>();

  addOrReplace(path: string, content: string): void {
    this.remove(path, false);
    const terms: string[] = SearchIndex.terms(content);
    this.documentTerms.set(path, terms);
    for (let i = 0; i < terms.length; i++) {
      const existing: string[] | undefined = this.postings.get(terms[i]);
      const paths: string[] = existing === undefined ? [] : existing;
      paths.push(path);
      this.postings.set(terms[i], paths);
    }
  }

  remove(path: string, isDirectory: boolean): void {
    const paths: string[] = [];
    this.documentTerms.forEach((_terms: string[], candidate: string): void => {
      if (candidate === path || (isDirectory && candidate.startsWith(path + '/'))) {
        paths.push(candidate);
      }
    });
    for (let i = 0; i < paths.length; i++) {
      const oldTerms: string[] | undefined = this.documentTerms.get(paths[i]);
      if (oldTerms === undefined) {
        continue;
      }
      for (let j = 0; j < oldTerms.length; j++) {
        const posting: string[] | undefined = this.postings.get(oldTerms[j]);
        if (posting === undefined) {
          continue;
        }
        const kept: string[] = [];
        for (let k = 0; k < posting.length; k++) {
          if (posting[k] !== paths[i]) {
            kept.push(posting[k]);
          }
        }
        if (kept.length === 0) {
          this.postings.delete(oldTerms[j]);
        } else {
          this.postings.set(oldTerms[j], kept);
        }
      }
      this.documentTerms.delete(paths[i]);
    }
  }

  retarget(oldPath: string, newPath: string, isDirectory: boolean): void {
    const moved: Array<[string, string[]]> = [];
    this.documentTerms.forEach((terms: string[], path: string): void => {
      if (path === oldPath || (isDirectory && path.startsWith(oldPath + '/'))) {
        moved.push([path, terms]);
      }
    });
    for (let i = 0; i < moved.length; i++) {
      const old: string = moved[i][0];
      const updated: string = newPath + old.substring(oldPath.length);
      this.remove(old, false);
      this.setTerms(updated, moved[i][1]);
    }
  }

  search(query: string, readCurrent: (path: string) => string | null): FullTextSearchResult[] {
    const normalized: string = query.trim().toLowerCase();
    if (normalized.length === 0) {
      return [];
    }
    const queryTerms: string[] = SearchIndex.terms(normalized);
    let candidates: string[] | null = null;
    for (let i = 0; i < queryTerms.length; i++) {
      const posting: string[] | undefined = this.postings.get(queryTerms[i]);
      if (posting === undefined) {
        return [];
      }
      if (candidates === null) {
        candidates = posting.slice();
      } else {
        const allowed: Set<string> = new Set<string>(posting);
        candidates = candidates.filter((path: string): boolean => allowed.has(path));
      }
      if (candidates.length === 0) {
        return [];
      }
    }

    const ordered: string[] = candidates === null ? [] : candidates;
    ordered.sort((left: string, right: string): number => left < right ? -1 : (left > right ? 1 : 0));
    const results: FullTextSearchResult[] = [];
    for (let i = 0; i < ordered.length; i++) {
      const content: string | null = readCurrent(ordered[i]);
      if (content === null) {
        continue;
      }
      const contentLower: string = content.toLowerCase();
      const matchAt: number = contentLower.indexOf(normalized);
      if (matchAt < 0) {
        continue;
      }
      results.push({ path: ordered[i], excerpt: SearchIndex.excerpt(content, matchAt, normalized.length) });
    }
    return results;
  }

  private setTerms(path: string, terms: string[]): void {
    this.remove(path, false);
    this.documentTerms.set(path, terms);
    for (let i = 0; i < terms.length; i++) {
      const existing: string[] | undefined = this.postings.get(terms[i]);
      const paths: string[] = existing === undefined ? [] : existing;
      paths.push(path);
      this.postings.set(terms[i], paths);
    }
  }

  private static terms(text: string): string[] {
    const normalized: string = text.toLowerCase();
    const seen: Set<string> = new Set<string>();
    const terms: string[] = [];
    for (let i = 0; i < normalized.length; i++) {
      const one: string = normalized.substring(i, i + 1);
      if (!seen.has(one)) {
        seen.add(one);
        terms.push(one);
      }
      if (i + 1 < normalized.length) {
        const two: string = normalized.substring(i, i + 2);
        if (!seen.has(two)) {
          seen.add(two);
          terms.push(two);
        }
      }
    }
    return terms;
  }

  private static excerpt(content: string, matchAt: number, matchLength: number): string {
    const start: number = Math.max(0, matchAt - 36);
    const end: number = Math.min(content.length, matchAt + matchLength + 64);
    const prefix: string = start > 0 ? '…' : '';
    const suffix: string = end < content.length ? '…' : '';
    return prefix + content.substring(start, end).replace(/\s+/g, ' ').trim() + suffix;
  }
}
