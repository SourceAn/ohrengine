/**
 * VocabularyBook - Vocabulary storage with JSON file persistence
 *
 * Manages saved vocabulary words at runtime via a Map<string, VocabularyItem>
 * and persists to a JSON file at {filesDir}/vocabulary.json.
 *
 * Persistence:
 *   - Load from file on first read access (lazy load)
 *   - Save to file after every write operation (add / remove)
 */

import { WordEntry, VocabularyItem } from '../model/WordEntry.ets';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const VOCABULARY_FILE_NAME: string = 'vocabulary.json';

export class VocabularyBook {
  private items: Map<string, VocabularyItem> = new Map();
  private filesDir: string = '';
  private loaded: boolean = false;

  constructor(filesDir: string) {
    this.filesDir = filesDir;
  }

  /**
   * Get all saved vocabulary items, sorted by savedAt descending.
   */
  public getAll(): VocabularyItem[] {
    this.ensureLoaded();
    const result: VocabularyItem[] = [];
    this.items.forEach((value: VocabularyItem) => {
      result.push(value);
    });
    result.sort((a: VocabularyItem, b: VocabularyItem) => {
      return b.savedAt - a.savedAt;
    });
    return result;
  }

  /**
   * Get a vocabulary item by word (case-insensitive).
   * Returns undefined if not saved.
   */
  public get(word: string): VocabularyItem | undefined {
    this.ensureLoaded();
    return this.items.get(word.toLowerCase().trim());
  }

  /**
   * Check if a word is already saved (case-insensitive).
   */
  public has(word: string): boolean {
    this.ensureLoaded();
    return this.items.has(word.toLowerCase().trim());
  }

  /**
   * Add a word entry to the vocabulary book.
   * Saves the phonetic and English definition from the lookup result.
   */
  public async add(entry: WordEntry): Promise<void> {
    this.ensureLoaded();
    const key: string = entry.word.toLowerCase().trim();
    const item: VocabularyItem = {
      word: entry.word,
      phonetic: entry.phonetic,
      definition: entry.definitionEn,
      savedAt: new Date().getTime()
    };
    this.items.set(key, item);
    await this.saveToFile();
  }

  /**
   * Remove a word from the vocabulary book (case-insensitive).
   */
  public async remove(word: string): Promise<void> {
    this.ensureLoaded();
    const key: string = word.toLowerCase().trim();
    this.items.delete(key);
    await this.saveToFile();
  }

  /**
   * Export all vocabulary as CSV string.
   * Columns: word, phonetic, definition, savedAt (ISO date string)
   */
  public async exportCsv(): Promise<string> {
    this.ensureLoaded();
    const header: string = 'word,phonetic,definition,savedAt';
    const rows: string[] = [header];

    // Collect and sort by savedAt descending
    const all: VocabularyItem[] = this.getAll();
    for (const item of all) {
      const dateStr: string = new Date(item.savedAt).toISOString().split('T')[0];
      // Escape commas in definition by wrapping in quotes
      const def: string = item.definition.replace(/"/g, '""');
      rows.push(item.word + ',"' + item.phonetic + '","' + def + '",' + dateStr);
    }
    return rows.join('\n');
  }

  /**
   * Get the file path for vocabulary JSON storage.
   */
  private getFilePath(): string {
    return this.filesDir + '/' + VOCABULARY_FILE_NAME;
  }

  /**
   * Ensure the vocabulary data is loaded from disk.
   * Operates in memory-only mode if filesDir is empty.
   */
  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    if (this.filesDir.length === 0) {
      return;
    }
    try {
      const filePath: string = this.getFilePath();
      if (fileIo.accessSync(filePath)) {
        const content: string = fileIo.readTextSync(filePath) as string;
        if (content.length > 0) {
          const jsonArr: VocabularyItem[] = JSON.parse(content) as VocabularyItem[];
          for (const item of jsonArr) {
            const key: string = item.word.toLowerCase().trim();
            this.items.set(key, item);
          }
        }
      }
    } catch (err) {
      // File not found or parse error — start with empty vocabulary
    }
  }

  /**
   * Persist the vocabulary data to JSON file.
   * Silently skips if filesDir is empty.
   */
  private async saveToFile(): Promise<void> {
    if (this.filesDir.length === 0) {
      return;
    }
    try {
      const filePath: string = this.getFilePath();
      const all: VocabularyItem[] = [];
      this.items.forEach((value: VocabularyItem) => {
        all.push(value);
      });
      const jsonStr: string = JSON.stringify(all);
      const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, jsonStr);
      fileIo.closeSync(file);
    } catch (err) {}
  }
}
