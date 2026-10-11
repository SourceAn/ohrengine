/**
 * FeatureManager — Business Feature Layer
 *
 * Encapsulates dictionary lookup, TTS, vocabulary book, and translation
 * features that sit on top of the core engine pipeline. Receives an
 * OhEngineCore reference but does NOT expose or mutate core internals.
 *
 * This is NOT the public API entry point. Use OhEngine (facade) for
 * all external consumption.
 */

import { WordEntry, VocabularyItem } from './model/WordEntry.ets';
import { DictionaryProvider, BuiltinDictionary, FreeDictionaryAPI, TranslationProvider, BuiltinTranslationProvider } from './dictionary/DictionaryService.ets';
import { DictionaryScheduler, DictionaryConfigManager, OnlineApiConfig, CustomAPIProvider } from './dictionary/DictionaryScheduler.ets';
import { VocabularyBook } from './vocabulary/VocabularyBook.ets';

/**
 * FeatureManager — TTS, dictionary, vocabulary, translation.
 * All fields are public for direct access when needed.
 */
export class FeatureManager {
  /** Dictionary lookup scheduler with provider priority chain */
  readonly dictionaryScheduler: DictionaryScheduler = new DictionaryScheduler();
  /** Built-in word reference provider (first fallback) */
  readonly builtinDictionary: BuiltinDictionary = new BuiltinDictionary();
  /** Free Dictionary API provider (primary online source) */
  freeDictionaryApi: FreeDictionaryAPI = new FreeDictionaryAPI(
    'https://api.dictionaryapi.dev/api/v2/entries/en', 'Free Dictionary API');
  /** Persistent configuration manager for API endpoints */
  configManager: DictionaryConfigManager | null = null;
  /** Text-to-speech engine instance (stubbed — TTS module unavailable in this SDK) */
  ttsEngine: Object | undefined = undefined;
  /** Vocabulary book for saved words */
  vocabularyBook: VocabularyBook = new VocabularyBook('');
  /** Translation provider (default: placeholder) */
  translationProvider: TranslationProvider = new BuiltinTranslationProvider();

  /**
   * Register built-in features (dictionary, TTS, translation providers).
   * Called once during engine initialization.
   */
  public static registerBuiltinFeatures(): void {
  }

  constructor() {
    // Initialize dictionary scheduler: FreeDictionaryAPI (priority 10) first,
    // BuiltinDictionary (20) as fallback
    this.dictionaryScheduler.addProvider(this.freeDictionaryApi, 10);
    this.dictionaryScheduler.addProvider(this.builtinDictionary, 20);
  }

  // ==================== Word Lookup ====================

  /** Look up a word via the dictionary scheduler (tries providers in priority order) */
  public lookupWord(word: string): Promise<WordEntry | null> {
    return this.dictionaryScheduler.lookup(word);
  }

  /**
   * Batch look up every word in a sentence.
   * Splits the text by whitespace, strips non-alphanumeric characters,
   * filters single-character tokens, and looks up each unique word.
   */
  public async lookupBatch(text: string): Promise<Map<string, WordEntry | null>> {
    const sep: RegExp = new RegExp('\\s+');
    const clean: RegExp = new RegExp('[^a-zA-Z\\u4E00-\\u9FFF]', 'g');
    const raw: string[] = text.split(sep);
    const words: string[] = [];
    for (let r: number = 0; r < raw.length; r++) {
      const w: string = raw[r].replace(clean, '');
      if (w.length > 1) {
        words.push(w);
      }
    }
    const results: Map<string, WordEntry | null> = new Map();
    for (let i: number = 0; i < words.length; i++) {
      const word: string = words[i];
      if (results.has(word)) {
        continue;
      }
      try {
        const entry: WordEntry | null = await this.dictionaryScheduler.lookup(word);
        results.set(word, entry);
      } catch (_e) {
        results.set(word, null);
      }
    }
    return results;
  }

  /**
   * Update the Free Dictionary API base URL and persist to config.
   * The FreeDictionaryAPI is recreated with the new URL and re-registered.
   */
  public updateFreeDictionaryApiConfig(apiUrl: string): void {
    if (this.configManager !== null) {
      this.configManager.updateConfig('Free Dictionary API', { apiUrl: apiUrl });
    }
    this.freeDictionaryApi = new FreeDictionaryAPI(apiUrl);
    this.dictionaryScheduler.addProvider(this.freeDictionaryApi, 10);
  }

  /** Initialize the DictionaryConfigManager with the app's filesDir */
  public initDictionaryConfigManager(filesDir: string): void {
    this.configManager = new DictionaryConfigManager(filesDir);
    // Load saved configs and register providers
    const savedConfigs: OnlineApiConfig[] = this.configManager.loadConfigs();
    for (let i: number = 0; i < savedConfigs.length; i++) {
      const cfg: OnlineApiConfig = savedConfigs[i];
      if (cfg.apiUrl !== undefined && cfg.apiUrl.length > 0) {
        // This is a Free Dictionary API config — recreate with user's apiUrl
        this.freeDictionaryApi = new FreeDictionaryAPI(cfg.apiUrl, cfg.name);
        this.dictionaryScheduler.addProvider(this.freeDictionaryApi, cfg.priority);
      } else if (cfg.endpoint.length > 0) {
        // This is a user-defined custom API provider
        const customProvider: CustomAPIProvider = new CustomAPIProvider(
          cfg.name, cfg.endpoint, cfg.priority
        );
        this.dictionaryScheduler.addProvider(customProvider, cfg.priority);
      }
    }
  }

  /** Add a user-custom API endpoint as a new dictionary provider */
  public addCustomDictionary(name: string, endpoint: string): void {
    const priority: number = 5; // Custom providers get highest priority (lower number)
    const provider: CustomAPIProvider = new CustomAPIProvider(name, endpoint, priority);
    this.dictionaryScheduler.addProvider(provider, priority);
    // Persist to config file if manager is initialized
    if (this.configManager !== null) {
      this.configManager.addConfig({
        name: name,
        endpoint: endpoint,
        priority: priority
      });
    }
  }

  // ==================== TTS ====================

  /**
   * Speak the given word using TTS.
   * Currently stubbed — @kit.CoreSpeechKit is not available in this SDK build.
   */
  public async speakWord(word: string): Promise<void> {
  }

  /** Stop any ongoing TTS speech (stubbed) */
  public stopSpeaking(): void {
  }

  // ==================== Vocabulary Book ====================

  /**
   * Set the storage directory path for vocabulary persistence.
   * Must be called before save/load operations.
   * Typically called from Index.ets with ctx.filesDir.
   */
  public setVocabularyStoragePath(filesDir: string): void {
    this.vocabularyBook = new VocabularyBook(filesDir);
  }

  /** Get all saved vocabulary items, sorted by savedAt descending. */
  public getVocabulary(): VocabularyItem[] {
    return this.vocabularyBook.getAll();
  }

  /** Save a word entry to the vocabulary book. */
  public async saveWordToVocabulary(entry: WordEntry): Promise<void> {
    await this.vocabularyBook.add(entry);
  }

  /** Remove a word from the vocabulary book (case-insensitive). */
  public async removeWordFromVocabulary(word: string): Promise<void> {
    await this.vocabularyBook.remove(word);
  }

  /** Check if a word is saved in the vocabulary book (case-insensitive). */
  public isWordSaved(word: string): boolean {
    return this.vocabularyBook.has(word);
  }

  /** Export all vocabulary items as a CSV string. */
  public async exportVocabularyAsCsv(): Promise<string> {
    return await this.vocabularyBook.exportCsv();
  }

  // ==================== Translation ====================

  /** Set the translation provider (default is BuiltinTranslationProvider placeholder). */
  public setTranslationProvider(provider: TranslationProvider): void {
    this.translationProvider = provider;
  }

  /** Translate a sentence from English to Chinese. */
  public async translateSentence(sentence: string): Promise<string> {
    return await this.translationProvider.translate(sentence, 'en', 'zh');
  }
}
