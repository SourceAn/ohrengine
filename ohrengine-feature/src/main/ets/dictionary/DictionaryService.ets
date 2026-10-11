/**
 * DictionaryService - Dictionary and translation provider interfaces + implementations
 *
 * Provides:
 * 1. DictionaryProvider interface - abstract dictionary lookup contract
 * 2. TranslationProvider interface - abstract translation contract
 * 3. BuiltinDictionary - in-memory dictionary with 10 demo words
 * 4. FreeDictionaryAPI - real HTTP dictionary lookup via Free Dictionary API with in-memory cache
 * 5. BuiltinTranslationProvider - placeholder translation implementation
 */

import { WordEntry } from '../model/WordEntry.ets';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * DictionaryProvider - Abstract interface for dictionary lookup.
 *
 * Each provider has a display name and a lookup method that returns
 * a WordEntry or null if the word is not found.
 */
export interface DictionaryProvider {
  /** Display name of this dictionary source */
  readonly name: string;
  /** Look up a word, returning WordEntry or null if not found */
  lookup(word: string): Promise<WordEntry | null>;
}

/**
 * TranslationProvider - Abstract interface for sentence translation.
 *
 * Translates a sentence from source language to target language.
 */
export interface TranslationProvider {
  /** Translate sentence from sourceLang to targetLang */
  translate(sentence: string, sourceLang: string, targetLang: string): Promise<string>;
}

/**
 * BuiltinDictionary - In-memory dictionary with 10 demo English words.
 *
 * Contains IPA, English/Chinese definitions, and example sentences for
 * common English words. Returns null for words not in the demo set.
 * Synchronous — returns an already-resolved Promise.
 */
export class BuiltinDictionary implements DictionaryProvider {
  readonly name: string = 'Built-in';
  private words: Record<string, WordEntry> = {};

  constructor() {
    this.initDemoWords();
  }

  private initDemoWords(): void {
    const w1: WordEntry = {
      word: 'serendipity',
      phonetic: '/ˌserənˈdɪpəti/',
      definitionEn: 'The occurrence and development of events by chance in a happy or beneficial way.',
      definitionZh: '意外发现美好事物的运气；机缘巧合',
      examples: ['A fortunate stroke of serendipity brought them together again.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['serendipity'] = w1;

    const w2: WordEntry = {
      word: 'ephemeral',
      phonetic: '/ɪˈfemərəl/',
      definitionEn: 'Lasting for a very short time; fleeting.',
      definitionZh: '短暂的；转瞬即逝的',
      examples: ['The ephemeral beauty of cherry blossoms reminds us to cherish each moment.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['ephemeral'] = w2;

    const w3: WordEntry = {
      word: 'ubiquitous',
      phonetic: '/juːˈbɪkwɪtəs/',
      definitionEn: 'Present, appearing, or found everywhere.',
      definitionZh: '无处不在的；普遍存在的',
      examples: ['Smartphones have become ubiquitous in modern society.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['ubiquitous'] = w3;

    const w4: WordEntry = {
      word: 'eloquent',
      phonetic: '/ˈeləkwənt/',
      definitionEn: 'Fluent or persuasive in speaking or writing; clearly expressing feelings or opinions.',
      definitionZh: '雄辩的；有口才的；富于表情的',
      examples: ['She delivered an eloquent speech that moved the audience to tears.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['eloquent'] = w4;

    const w5: WordEntry = {
      word: 'resilient',
      phonetic: '/rɪˈzɪliənt/',
      definitionEn: 'Able to withstand or recover quickly from difficult conditions.',
      definitionZh: '有弹性的；能迅速恢复的；适应力强的',
      examples: ['Children are remarkably resilient and can adapt to new environments quickly.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['resilient'] = w5;

    const w6: WordEntry = {
      word: 'ambiguous',
      phonetic: '/æmˈbɪɡjuəs/',
      definitionEn: 'Open to more than one interpretation; having a double meaning.',
      definitionZh: '模棱两可的；含糊不清的',
      examples: ['The contract language was deliberately ambiguous to leave room for negotiation.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['ambiguous'] = w6;

    const w7: WordEntry = {
      word: 'pragmatic',
      phonetic: '/præɡˈmætɪk/',
      definitionEn: 'Dealing with things sensibly and realistically; practical rather than idealistic.',
      definitionZh: '务实的；实用的；讲究实际的',
      examples: ['We need a pragmatic approach to solve this budget crisis.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['pragmatic'] = w7;

    const w8: WordEntry = {
      word: 'nostalgia',
      phonetic: '/nɒˈstældʒə/',
      definitionEn: 'A sentimental longing or wistful affection for the past.',
      definitionZh: '怀旧；乡愁；对过去的留恋',
      examples: ['The old photographs filled her with nostalgia for her childhood.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['nostalgia'] = w8;

    const w9: WordEntry = {
      word: 'ineffable',
      phonetic: '/ɪnˈefəb(ə)l/',
      definitionEn: 'Too great or extreme to be expressed or described in words.',
      definitionZh: '不可言喻的；难以形容的',
      examples: ['The beauty of the sunset was ineffable, leaving us all speechless.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['ineffable'] = w9;

    const w10: WordEntry = {
      word: 'hello',
      phonetic: '/həˈloʊ/',
      definitionEn: 'Used as a greeting or to begin a conversation.',
      definitionZh: '你好；喂',
      examples: ['Hello, how are you today?', 'She said hello to everyone she met.'],
      source: 'Built-in',
      sentence: ''
    };
    this.words['hello'] = w10;
  }

  /**
   * Look up a word in the built-in dictionary.
   * Returns the WordEntry if found, or null if the word is not in the demo set.
   */
  lookup(word: string): Promise<WordEntry | null> {
    const lowerWord: string = word.toLowerCase().trim();
    const entry: WordEntry | undefined = this.words[lowerWord];
    if (entry !== undefined) {
      return Promise.resolve(entry);
    }
    return Promise.resolve(null);
  }
}

/**
 * FreeDictionaryAPI - Real HTTP dictionary lookup via the Free Dictionary API
 * (https://api.dictionaryapi.dev/api/v2/entries/en/) with in-memory cache.
 *
 * Flow:
 *   1. Check in-memory cache first (case-insensitive key)
 *   2. On cache hit → return cached WordEntry with source 'Free Dictionary API (cached)'
 *   3. On cache miss → HTTP GET to the Free Dictionary API
 *   4. On 200 OK → parse JSON response, cache result, return with source 'Free Dictionary API'
 *   5. On any error/404 → return null
 *
 * The source field distinguishes fresh vs cached results.
 */
export class FreeDictionaryAPI implements DictionaryProvider {
  readonly name: string;
  private apiBaseUrl: string;
  private cache: Map<string, WordEntry> = new Map();

  constructor(customEndpoint?: string, customName?: string) {
    this.apiBaseUrl = customEndpoint !== undefined && customEndpoint.length > 0
      ? customEndpoint
      : 'https://api.dictionaryapi.dev/api/v2/entries/en/';
    this.name = customName !== undefined && customName.length > 0
      ? customName
      : 'Free Dictionary API';
    // Ensure apiBaseUrl ends with /
    if (this.apiBaseUrl.length > 0 && this.apiBaseUrl[this.apiBaseUrl.length - 1] !== '/') {
      this.apiBaseUrl += '/';
    }
  }

  /**
   * Look up a word via the Free Dictionary API with caching.
   */
  async lookup(word: string): Promise<WordEntry | null> {
    const key: string = word.toLowerCase().trim();
    if (key.length === 0) {
      return null;
    }

    // 1. Check in-memory cache
    const cached: WordEntry | undefined = this.cache.get(key);
    if (cached !== undefined) {
      return {
        word: cached.word,
        phonetic: cached.phonetic,
        definitionEn: cached.definitionEn,
        definitionZh: cached.definitionZh,
        examples: cached.examples,
        source: 'Free Dictionary API (cached)',
        sentence: cached.sentence
      };
    }

    // 2. HTTP GET to the Free Dictionary API
    try {
      const httpRequest: http.HttpRequest = http.createHttp();
      const url: string = this.apiBaseUrl + encodeURIComponent(key);

      // 安全校验（ENG-013）：仅允许 https，防止明文端点
      if (!url.toLowerCase().startsWith('https://')) {
        return null;
      }

      const response: http.HttpResponse = await new Promise<http.HttpResponse>(
        (resolve: (value: http.HttpResponse) => void, reject: (reason: Error) => void) => {
          httpRequest.request(
            url,
            {
              method: http.RequestMethod.GET,
              connectTimeout: 10000,
              readTimeout: 10000,
              expectDataType: http.HttpDataType.STRING
            },
            (err: BusinessError | null, data: http.HttpResponse) => {
              httpRequest.destroy();
              if (err !== null && err !== undefined) {
                reject(new Error(err.message));
              } else {
                resolve(data);
              }
            }
          );
        }
      );

      // 3. Handle response
      if (response.responseCode === 200) {
        const raw: string = response.result as string;
        // 响应体大小上限（ENG-013）：50 KB
        if (raw.length > 50000) {
          return null;
        }
        const entry: WordEntry | null = this.parseApiResponse(raw, word);
        if (entry !== null) {
          // Cache the result (mark as fresh, without cache tag)
          this.cache.set(key, entry);
          return {
            word: entry.word,
            phonetic: entry.phonetic,
            definitionEn: entry.definitionEn,
            definitionZh: entry.definitionZh,
            examples: entry.examples,
            source: 'Free Dictionary API',
            sentence: entry.sentence
          };
        }
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  /**
   * Parse the Free Dictionary API JSON response into a WordEntry.
   * The API returns an array of entries; we use the first one.
   */
  private parseApiResponse(raw: string, originalWord: string): WordEntry | null {
    try {
      const parsed: Object = JSON.parse(raw);
      const entries: FreeDictEntry[] = parsed as FreeDictEntry[];
      if (entries.length === 0) {
        return null;
      }
      const first: FreeDictEntry = entries[0];
      let phonetic: string = first.phonetic ?? '';
      if (phonetic.length === 0 && first.phonetics !== undefined && first.phonetics.length > 0) {
        phonetic = first.phonetics[0].text ?? '';
      }
      const defParts: string[] = [];
      const examples: string[] = [];
      for (let i: number = 0; i < first.meanings.length; i++) {
        const meaning: FreeDictMeaning = first.meanings[i];
        for (let j: number = 0; j < meaning.definitions.length; j++) {
          const def: FreeDictDefinition = meaning.definitions[j];
          defParts.push('[' + meaning.partOfSpeech + '] ' + def.definition);
          if (def.example !== undefined && def.example.length > 0 && examples.length < 3) {
            examples.push(def.example);
          }
        }
      }
      return {
        word: originalWord,
        phonetic: phonetic,
        definitionEn: defParts.join('\n'),
        definitionZh: '',
        examples: examples,
        source: 'Free Dictionary API',
        sentence: ''
      } as WordEntry;
    } catch (_e) {
      return null;
    }
  }

  /**
   * Clear the in-memory cache.
   */
  clearCache(): void {
    this.cache.clear();
  }
}

// ── Free Dictionary API response type helpers ──

interface FreeDictEntry {
  word: string;
  phonetic: string;
  phonetics: FreeDictPhonetic[];
  meanings: FreeDictMeaning[];
}

interface FreeDictPhonetic {
  text: string;
  audio: string;
}

interface FreeDictMeaning {
  partOfSpeech: string;
  definitions: FreeDictDefinition[];
}

interface FreeDictDefinition {
  definition: string;
  example: string;
  synonyms: string[];
  antonyms: string[];
}

/**
 * BuiltinTranslationProvider - Placeholder translation implementation.
 *
 * Returns a message indicating translation service is not configured,
 * as @kit.TranslationKit does not exist as a standard HarmonyOS system kit.
 */
export class BuiltinTranslationProvider implements TranslationProvider {
  translate(sentence: string, _sourceLang: string, _targetLang: string): Promise<string> {
    // Placeholder: return a message that translation is not configured
    const msg: string = 'Translation service not configured. (Abstract — requires external API integration.)';
    return Promise.resolve(msg);
  }
}
