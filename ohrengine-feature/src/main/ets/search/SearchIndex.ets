/**
 * SearchIndex — full-text search for EPUB reading engine
 *
 * Strategy: linear per-chapter indexOf (EPUB ≤200 chapters, no inverted index needed)
 */
export interface SearchResult {
  chapterIndex: number;
  charOffset: number;
  matchLength: number;
  contextBefore: string;
  contextAfter: string;
}

export class FullTextSearch {
  private chapterTexts: string[] = [];

  /** Build index from plain-text chapters (call once on open) */
  buildIndex(chapters: string[]): void {
    this.chapterTexts = chapters;
  }

  /** Search and return at most maxResults results */
  search(query: string, maxResults: number = 50): SearchResult[] {
    if (query.length === 0 || this.chapterTexts.length === 0) {
      return [];
    }
    const q: string = query.toLowerCase();
    const results: SearchResult[] = [];
    for (let ch: number = 0; ch < this.chapterTexts.length && results.length < maxResults; ch++) {
      const text: string = this.chapterTexts[ch].toLowerCase();
      let pos: number = 0;
      while ((pos = text.indexOf(q, pos)) !== -1 && results.length < maxResults) {
        const ctxStart: number = Math.max(0, pos - 30);
        const ctxEnd: number = Math.min(text.length, pos + q.length + 30);
        const ctxBefore: string = this.chapterTexts[ch].substring(ctxStart, pos).trim();
        const ctxAfter: string = this.chapterTexts[ch].substring(pos + q.length, ctxEnd).trim();
        results.push({
          chapterIndex: ch,
          charOffset: pos,
          matchLength: query.length,
          contextBefore: ctxBefore,
          contextAfter: ctxAfter
        } as SearchResult);
        pos += 1;
      }
    }
    return results;
  }

  /** Whether index has been built */
  get isIndexed(): boolean {
    return this.chapterTexts.length > 0;
  }
}
