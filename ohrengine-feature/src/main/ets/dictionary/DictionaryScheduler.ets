/**
 * DictionaryScheduler - Provider orchestration, config persistence, and custom API provider
 *
 * Exports:
 * 1. OnlineApiConfig - interface for custom API configuration
 * 2. DictionaryConfigManager - persists API configs to {filesDir}/dictionary_config.json
 * 3. CustomAPIProvider - user-configurable HTTP dictionary provider with {word} placeholder
 * 4. DictionaryScheduler - priority-ordered fallback chain of DictionaryProvider instances
 */

import { WordEntry } from '../model/WordEntry.ets';
import { DictionaryProvider } from './DictionaryService.ets';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

// ── OnlineApiConfig ──

/**
 * Configuration for a user-defined custom API endpoint.
 * The endpoint URL must contain the literal placeholder {word}, which
 * is replaced with the encoded lookup word at request time.
 */
export interface OnlineApiConfig {
  /** Display name (e.g. "My Dictionary API") */
  name: string;
  /** Endpoint URL with {word} placeholder (e.g. "https://example.com/api/{word}") */
  endpoint: string;
  /** Priority — lower number = higher priority (same semantics as scheduler ordering) */
  priority: number;
  /** Base URL for the Free Dictionary API (if set, this config represents FreeDictionaryAPI) */
  apiUrl?: string;
}

// ── DictionaryConfigManager ──

/**
 * Manages serialization/deserialization of OnlineApiConfig entries
 * to a JSON file in the app's sandbox filesDir.
 *
 * Config file path: {filesDir}/dictionary_config.json
 */
export class DictionaryConfigManager {
  private configPath: string;

  constructor(filesDir: string) {
    this.configPath = filesDir + '/dictionary_config.json';
  }

  /**
   * Default built-in API configurations.
   * The Free Dictionary API entry includes an apiUrl for user modification.
   */
  getDefaultConfigs(): OnlineApiConfig[] {
    return [
      {
        name: 'Free Dictionary API',
        endpoint: '',
        priority: 10,
        apiUrl: 'https://api.dictionaryapi.dev/api/v2/entries/en'
      }
    ];
  }

  /**
   * Load saved API configurations from disk.
   * Returns default configs if the file does not exist or cannot be parsed.
   */
  loadConfigs(): OnlineApiConfig[] {
    try {
      const stat: fileIo.Stat = fileIo.statSync(this.configPath);
      if (stat.size === 0) {
        const defaults: OnlineApiConfig[] = this.getDefaultConfigs();
        this.saveConfigs(defaults);
        return defaults;
      }
      const file: fileIo.File = fileIo.openSync(this.configPath, fileIo.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const decoder: util.TextDecoder = new util.TextDecoder();
      const uint8Arr: Uint8Array = new Uint8Array(buf);
      const raw: string = decoder.decodeToString(uint8Arr);
      const parsed: Object = JSON.parse(raw);
      const arr: OnlineApiConfig[] = parsed as OnlineApiConfig[];
      if (arr.length === 0) {
        const defaults: OnlineApiConfig[] = this.getDefaultConfigs();
        this.saveConfigs(defaults);
        return defaults;
      }
      return arr;
    } catch (_e) {
      const defaults: OnlineApiConfig[] = this.getDefaultConfigs();
      this.saveConfigs(defaults);
      return defaults;
    }
  }

  /**
   * Save API configurations to disk as JSON.
   */
  saveConfigs(configs: OnlineApiConfig[]): void {
    try {
      const jsonStr: string = JSON.stringify(configs);
      const file: fileIo.File = fileIo.openSync(
        this.configPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      const encoder: util.TextEncoder = new util.TextEncoder();
      const uint8Arr: Uint8Array = encoder.encodeInto(jsonStr);
      const buf: ArrayBuffer = uint8Arr.buffer as ArrayBuffer;
      fileIo.writeSync(file.fd, buf);
      fileIo.closeSync(file);
    } catch (_e) {}
  }

  /**
   * Add a new config entry and persist.
   */
  addConfig(config: OnlineApiConfig): void {
    const configs: OnlineApiConfig[] = this.loadConfigs();
    configs.push(config);
    this.saveConfigs(configs);
  }

  /**
   * Remove a config entry by name and persist.
   */
  removeConfig(name: string): void {
    const configs: OnlineApiConfig[] = this.loadConfigs();
    const filtered: OnlineApiConfig[] = [];
    for (let i: number = 0; i < configs.length; i++) {
      if (configs[i].name !== name) {
        filtered.push(configs[i]);
      }
    }
    this.saveConfigs(filtered);
  }

  /**
   * Update fields of a named config entry and persist.
   * Only the provided fields from `updates` are applied; others remain unchanged.
   */
  updateConfig(name: string, updates: Partial<OnlineApiConfig>): void {
    const configs: OnlineApiConfig[] = this.loadConfigs();
    for (let i: number = 0; i < configs.length; i++) {
      if (configs[i].name === name) {
        if (updates.apiUrl !== undefined) {
          configs[i].apiUrl = updates.apiUrl;
        }
        if (updates.endpoint !== undefined) {
          configs[i].endpoint = updates.endpoint;
        }
        if (updates.priority !== undefined) {
          configs[i].priority = updates.priority;
        }
        break;
      }
    }
    this.saveConfigs(configs);
  }
}

// ── CustomAPIProvider ──

/**
 * User-configurable dictionary provider that calls an arbitrary HTTP endpoint.
 *
 * The endpoint URL MUST contain the literal {word} placeholder, which
 * is replaced with the URL-encoded lookup word.
 *
 * Response handling:
 *   - Tries to parse the response as JSON
 *   - Looks for common fields: 'definition', 'definitions', 'meaning', 'meanings'
 *   - Falls back to first 200 chars of raw response text
 *   - Returns null on any failure
 */
export class CustomAPIProvider implements DictionaryProvider {
  readonly name: string;
  private endpointTemplate: string;
  private priority: number;
  private cache: Map<string, WordEntry> = new Map();

  constructor(name: string, endpoint: string, priority: number) {
    this.name = name;
    this.endpointTemplate = endpoint;
    this.priority = priority;
  }

  getPriority(): number {
    return this.priority;
  }

  async lookup(word: string): Promise<WordEntry | null> {
    const key: string = word.toLowerCase().trim();
    if (key.length === 0) {
      return null;
    }

    // Check cache
    const cached: WordEntry | undefined = this.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }

    // Build URL by replacing {word} placeholder
    const url: string = this.endpointTemplate.replace('{word}', encodeURIComponent(key));

    // 安全校验（ENG-013）：
    // 1) 仅允许 https（拒绝 http 明文端点，防止中间人/隐私泄露）
    // 2) 端点长度上限，防止异常配置
    const lowerUrl: string = url.toLowerCase();
    if (!lowerUrl.startsWith('https://')) {
      return null;
    }
    if (url.length > 2048) {
      return null;
    }

    try {
      const httpRequest: http.HttpRequest = http.createHttp();
      const response: http.HttpResponse = await new Promise<http.HttpResponse>(
        (resolve: (value: http.HttpResponse) => void, reject: (reason: Error) => void) => {
          httpRequest.request(
            url,
            {
              method: http.RequestMethod.GET,
              // 超时收紧（ENG-013）：连接 + 读取各 10s，避免长时间挂起阻塞查词
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

      if (response.responseCode === 200) {
        const raw: string = response.result as string;
        // 响应体大小上限（ENG-013）：50 KB，防止超大响应拖垮查词
        if (raw.length > 50000) {
          return null;
        }
        const entry: WordEntry | null = this.parseCustomResponse(raw, word);
        if (entry !== null) {
          this.cache.set(key, entry);
          return entry;
        }
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  /**
   * Try to extract definition data from an arbitrary API response.
   */
  private parseCustomResponse(raw: string, originalWord: string): WordEntry | null {
    try {
      const parsed: Object = JSON.parse(raw);
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      let definitionText: string = '';

      // Try common field names for definition data
      const possibleKeys: string[] = ['definition', 'definitions', 'meaning', 'meanings',
        'def', 'text', 'translation', 'explanation'];
      for (let i: number = 0; i < possibleKeys.length; i++) {
        const val: Object | undefined = obj[possibleKeys[i]];
        if (val !== undefined) {
          if (typeof val === 'string') {
            definitionText = val as string;
            break;
          } else if (val instanceof Array && val.length > 0) {
            const firstItem: Object = val[0];
            const itemObj: Record<string, Object> = firstItem as Record<string, Object>;
            if (typeof itemObj['definition'] === 'string') {
              definitionText = itemObj['definition'] as string;
              break;
            }
          }
        }
      }

      // Fallback to raw text if structured parsing failed
      if (definitionText.length === 0) {
        definitionText = raw.substring(0, 200);
      }

      return {
        word: originalWord,
        phonetic: '',
        definitionEn: definitionText,
        definitionZh: '',
        examples: [],
        source: this.name,
        sentence: ''
      } as WordEntry;
    } catch (_e) {
      // Not JSON or parse error — use raw text
      return {
        word: originalWord,
        phonetic: '',
        definitionEn: raw.substring(0, 200),
        definitionZh: '',
        examples: [],
        source: this.name,
        sentence: ''
      } as WordEntry;
    }
  }

  clearCache(): void {
    this.cache.clear();
  }
}

// ── DictionaryScheduler ──

/**
 * Entry wrapper associating a DictionaryProvider with its priority.
 */
interface ProviderEntry {
  provider: DictionaryProvider;
  priority: number;
}

/**
 * Describes a registered provider entry (name + priority).
 */
export interface ProviderDescriptor {
  name: string;
  priority: number;
}

/**
 * Priority-based dictionary scheduler.
 *
 * Manages a collection of DictionaryProvider instances sorted by priority
 * (ascending). On lookup, each provider is tried in order; the first
 * non-null result is returned immediately.
 *
 * Providers can be added/removed at runtime.
 */
export class DictionaryScheduler {
  private providers: ProviderEntry[] = [];

  /**
   * Add a provider with the given priority (lower = higher priority).
   * If a provider with the same name already exists, it is replaced.
   * Providers are re-sorted after each addition.
   */
  addProvider(provider: DictionaryProvider, priority: number): void {
    this.removeProvider(provider.name);
    this.providers.push({ provider: provider, priority: priority });
    this.sortProviders();
  }

  /**
   * Remove a provider by name. Returns true if found and removed.
   */
  removeProvider(name: string): boolean {
    const initialLength: number = this.providers.length;
    const filtered: ProviderEntry[] = [];
    for (let i: number = 0; i < this.providers.length; i++) {
      if (this.providers[i].provider.name !== name) {
        filtered.push(this.providers[i]);
      }
    }
    this.providers = filtered;
    return filtered.length < initialLength;
  }

  /**
   * Look up a word by trying each provider in priority order.
   * Returns the first non-null result, or null if all providers fail.
   */
  async lookup(word: string): Promise<WordEntry | null> {
    for (let i: number = 0; i < this.providers.length; i++) {
      const entry: ProviderEntry = this.providers[i];
      try {
        const result: WordEntry | null = await entry.provider.lookup(word);
        if (result !== null) {
          return result;
        }
      } catch (_e) {}
    }
    return null;
  }

  /**
   * Get all registered provider names and their priorities.
   */
  getProviders(): ProviderDescriptor[] {
    const result: ProviderDescriptor[] = [];
    for (let i: number = 0; i < this.providers.length; i++) {
      const desc: ProviderDescriptor = {
        name: this.providers[i].provider.name,
        priority: this.providers[i].priority
      } as ProviderDescriptor;
      result.push(desc);
    }
    return result;
  }

  /**
   * Get a specific provider by name (for cache management etc).
   */
  getProviderByName(name: string): DictionaryProvider | null {
    for (let i: number = 0; i < this.providers.length; i++) {
      if (this.providers[i].provider.name === name) {
        return this.providers[i].provider;
      }
    }
    return null;
  }

  /**
   * Clear all providers.
   */
  clearProviders(): void {
    this.providers = [];
  }

  /**
   * Re-sort providers by priority (ascending).
   */
  private sortProviders(): void {
    // Simple insertion sort — provider lists are small
    for (let i: number = 1; i < this.providers.length; i++) {
      const key: ProviderEntry = this.providers[i];
      let j: number = i - 1;
      while (j >= 0 && this.providers[j].priority > key.priority) {
        this.providers[j + 1] = this.providers[j];
        j--;
      }
      this.providers[j + 1] = key;
    }
  }
}
