/**
 * WordEntry - Data types for word lookup feature
 *
 * Provides core data interfaces used across the dictionary,
 * vocabulary, and lookup dialog components.
 */

/**
 * WordEntry - Represents a dictionary lookup result.
 *
 * Contains the word text, phonetic transcription (IPA), English/Chinese
 * definitions, example sentences, dictionary source name, and the
 * surrounding sentence for translation use.
 */
export interface WordEntry {
  /** The looked-up word text */
  word: string;
  /** IPA phonetic transcription (e.g. '/həˈloʊ/') */
  phonetic: string;
  /** English definition */
  definitionEn: string;
  /** Chinese definition */
  definitionZh: string;
  /** Example sentences (0-3) */
  examples: string[];
  /** Dictionary source name ('Built-in' / 'Online') */
  source: string;
  /** The full sentence containing the word (for translation) */
  sentence: string;
}

/**
 * VocabularyItem - Represents a word saved to the vocabulary book.
 *
 * Each item stores the word text, the phonetic and definition snapshot
 * from lookup time, and a Unix timestamp of when it was saved.
 */
export interface VocabularyItem {
  /** The word text (used as unique key, case-insensitive) */
  word: string;
  /** IPA phonetic transcription from lookup time */
  phonetic: string;
  /** Definition snapshot (English) from lookup time */
  definition: string;
  /** Unix timestamp of when saved */
  savedAt: number;
}
