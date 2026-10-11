/**
 * WordLookupDialog - Dictionary lookup result dialog
 *
 * A @CustomDialog that displays word details (IPA, definitions, examples)
 * after the user selects text and taps "Lookup" in the context menu.
 *
 * Data flow:
 *   Index.ets creates a CustomDialogController with this builder,
 *   setting `word` and `engine` fields before calling open().
 *   On appear, the dialog calls engine.lookupWord(word) and displays results.
 */

import { WordEntry } from 'ohrengine-feature';
import { OhEngine } from 'ohrengine-ui-render';

/**
 * Per-word result from a batch lookup.
 */
interface BatchResultItem {
  word: string;
  found: boolean;
  definition: string;
  phonetic: string;
  source: string;
}

@CustomDialog
export struct WordLookupDialog {
  controller: CustomDialogController;

  // Data set by caller before open()
  word: string = '';
  sentence: string = '';
  engine: OhEngine | null = null;

  @State wordEntry: WordEntry | null = null;
  @State isLoading: boolean = false;
  @State errorMessage: string = '';
  @State isSpeaking: boolean = false;
  @State isSaved: boolean = false;
  @State batchResultItems: BatchResultItem[] = [];
  @State isBatchLoading: boolean = false;
  aboutToAppear(): void {
    this.loadWordData();
    this.checkSavedStatus();
  }

  /** Stop TTS when dialog closes to avoid orphaned speech */
  aboutToDisappear(): void {
    if (this.engine !== null && this.isSpeaking) {
      this.engine.stopSpeaking();
      this.isSpeaking = false;
    }
  }

  private checkSavedStatus(): void {
    if (this.engine !== null && this.word.length > 0) {
      this.isSaved = this.engine.isWordSaved(this.word);
    }
  }

  private async loadWordData(): Promise<void> {
    if (this.engine === null || this.word.length === 0) {
      this.errorMessage = 'No word selected.';
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const result: WordEntry | null = await this.engine.lookupWord(this.word);
      if (result !== null) {
        // Set the sentence in the result for potential translation use
        result.sentence = this.sentence;
        this.wordEntry = result;
      } else {
        this.wordEntry = null;
        this.errorMessage = 'Word not found in dictionary.';
      }
    } catch (err) {
      this.wordEntry = null;
      this.errorMessage = 'Lookup failed: ' + (err instanceof Error ? err.message : String(err));
    } finally {
      this.isLoading = false;
    }
  }

  private async handleTtsToggle(): Promise<void> {
    if (this.engine === null) {
      return;
    }
    if (this.isSpeaking) {
      this.engine.stopSpeaking();
      this.isSpeaking = false;
    } else {
      this.isSpeaking = true;
      try {
        await this.engine.speakWord(this.word);
      } catch (err) {
        this.errorMessage = 'TTS failed: ' + (err instanceof Error ? err.message : String(err));
      } finally {
        this.isSpeaking = false;
      }
    }
  }

  private async handleSaveToggle(): Promise<void> {
    if (this.engine === null) {
      return;
    }
    if (this.isSaved) {
      try {
        await this.engine.removeWordFromVocabulary(this.word);
        this.isSaved = false;
      } catch (err) {
        this.errorMessage = 'Failed to remove word: ' + (err instanceof Error ? err.message : String(err));
      }
    } else {
      try {
        const entry: WordEntry = {
          word: this.word,
          phonetic: this.wordEntry !== null ? this.wordEntry.phonetic : '',
          definitionEn: this.wordEntry !== null ? this.wordEntry.definitionEn : '',
          definitionZh: this.wordEntry !== null ? this.wordEntry.definitionZh : '',
          examples: this.wordEntry !== null ? this.wordEntry.examples : [],
          source: this.wordEntry !== null ? this.wordEntry.source : 'builtin',
          sentence: this.sentence
        };
        await this.engine.saveWordToVocabulary(entry);
        this.isSaved = true;
      } catch (err) {
        this.errorMessage = 'Failed to save word: ' + (err instanceof Error ? err.message : String(err));
      }
    }
  }

  private async handleBatchLookup(): Promise<void> {
    if (this.engine === null || this.sentence.length === 0) {
      return;
    }
    this.isBatchLoading = true;
    this.batchResultItems = [];
    try {
      const results: Map<string, WordEntry | null> = await this.engine.lookupBatch(this.sentence);
      const items: BatchResultItem[] = [];
      // Convert Map entries to array — iterate via key array
      const keys: string[] = [];
      results.forEach((_value: WordEntry | null, key: string): void => {
        keys.push(key);
      });
      for (let i: number = 0; i < keys.length; i++) {
        const word: string = keys[i];
        const entry: WordEntry | null = results.get(word) as WordEntry | null;
        if (entry !== null) {
          items.push({
            word: word,
            found: true,
            definition: entry.definitionEn.length > 0 ? entry.definitionEn : entry.definitionZh,
            phonetic: entry.phonetic,
            source: entry.source
          });
        } else {
          items.push({
            word: word,
            found: false,
            definition: '（未找到释义）',
            phonetic: '',
            source: ''
          });
        }
      }
      this.batchResultItems = items;
    } catch (err) {
      this.batchResultItems = [{
        word: 'Error',
        found: false,
        definition: '查询失败: ' + (err instanceof Error ? err.message : String(err)),
        phonetic: '',
        source: ''
      }];
    } finally {
      this.isBatchLoading = false;
    }
  }

  build(): void {
    Column() {
      if (this.isLoading) {
        // Loading state
        LoadingProgress()
          .width(32).height(32).margin({ top: 40, bottom: 40 })
        Text('Looking up...').fontSize(14).fontColor('#888888')
      } else if (this.wordEntry !== null) {
        // Word header: word text + phonetic
        Row() {
          Text(this.wordEntry.word)
            .fontSize(24).fontWeight(FontWeight.Bold).fontColor('#1a1a1a')
            .layoutWeight(1)
          Text(this.wordEntry.phonetic)
            .fontSize(16).fontColor('#666666')
            .fontStyle(FontStyle.Italic)
        }
        .width('100%')
        .margin({ top: 8, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        // English definition
        Text(this.wordEntry.definitionEn)
          .fontSize(15).fontColor('#333333')
          .width('100%')
          .margin({ bottom: 10 })

        // Chinese definition
        Text(this.wordEntry.definitionZh)
          .fontSize(15).fontColor('#333333')
          .width('100%')
          .margin({ bottom: 12 })

        // Examples section
        if (this.wordEntry.examples.length > 0) {
          Text('Examples')
            .fontSize(13).fontWeight(FontWeight.Bold).fontColor('#999999')
            .width('100%')
            .margin({ bottom: 6 })

          ForEach(this.wordEntry.examples, (example: string) => {
            Row() {
              Text('• ')
                .fontSize(14).fontColor('#0078D4')
                .margin({ right: 4 })
              Text(example)
                .fontSize(14).fontColor('#555555')
                .fontStyle(FontStyle.Italic)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ bottom: 6 })
          }, (example: string) => example)
        }

        // Source indicator — shows which provider returned the result
        if (this.wordEntry.source.length > 0) {
          Row() {
            Text('Source: ')
              .fontSize(11).fontColor('#aaaaaa')
            Text(this.wordEntry.source)
              .fontSize(11).fontWeight(FontWeight.Bold)
              .fontColor('#0078D4')
          }
          .width('100%')
          .margin({ top: 12, bottom: 4 })
        }

        // Action buttons row: TTS + Save toggle + Translate
        Row() {
          Button(this.isSpeaking ? 'Stop' : 'Play')
            .fontSize(14).height(36).padding({ left: 20, right: 20 })
            .backgroundColor(this.isSpeaking ? '#ff4444' : '#0078D4')
            .fontColor('#ffffff').borderRadius(18)
            .onClick(() => {
              this.handleTtsToggle();
            })

          Button(this.isSaved ? '✓ Saved' : '+ Save')
            .fontSize(14).height(36).padding({ left: 20, right: 20 })
            .backgroundColor(this.isSaved ? '#4CAF50' : '#FF9800')
            .fontColor('#ffffff').borderRadius(18)
            .margin({ left: 12 })
            .onClick(() => {
              this.handleSaveToggle();
            })

          Button('翻译整句')
            .fontSize(14).height(36).padding({ left: 20, right: 20 })
            .backgroundColor(this.sentence.length > 0 ? '#9C27B0' : '#cccccc')
            .fontColor('#ffffff').borderRadius(18)
            .margin({ left: 12 })
            .enabled(this.sentence.length > 0)
            .onClick(() => {
              this.handleBatchLookup();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 12, bottom: 4 })

        // Batch lookup results
        if (this.isBatchLoading) {
          Row() {
            LoadingProgress().width(16).height(16).margin({ right: 8 })
            Text('逐词查询中...').fontSize(13).fontColor('#888888')
          }
          .width('100%')
          .margin({ top: 8, bottom: 4 })
        }
        if (this.batchResultItems.length > 0) {
          Column() {
            Text('整句逐词释义:')
              .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#9C27B0')
              .width('100%')
              .margin({ bottom: 6 })
            ForEach(this.batchResultItems, (item: BatchResultItem) => {
              Row() {
                Text(item.word)
                  .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333333')
                  .margin({ right: 6 })
                if (item.phonetic.length > 0) {
                  Text(item.phonetic)
                    .fontSize(12).fontColor('#888888').fontStyle(FontStyle.Italic)
                    .margin({ right: 6 })
                }
                Text(item.found ? item.definition : item.definition)
                  .fontSize(13).fontColor(item.found ? '#555555' : '#aaaaaa')
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 4, bottom: 4 })
            }, (item: BatchResultItem): string => item.word)
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#f3e5f5')
          .borderRadius(6)
          .margin({ top: 8, bottom: 4 })
        }
      } else {
        // No definition found (non-English / not in dictionary) — still offer TTS + Save + Translate
        Column() {
          Text(this.word)
            .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1a1a1a')
            .margin({ top: 20, bottom: 12 })
          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(14).fontColor('#888888')
              .margin({ bottom: 8 })
          } else {
            Text('暂无释义')
              .fontSize(14).fontColor('#888888')
              .margin({ bottom: 8 })
          }
          // Action buttons row: TTS + Save toggle + Translate
          Row() {
            Button(this.isSpeaking ? 'Stop' : 'Play')
              .fontSize(14).height(36).padding({ left: 20, right: 20 })
              .backgroundColor(this.isSpeaking ? '#ff4444' : '#0078D4')
              .fontColor('#ffffff').borderRadius(18)
              .margin({ top: 8 })
              .onClick(() => {
                this.handleTtsToggle();
              })

            Button(this.isSaved ? '✓ Saved' : '+ Save')
              .fontSize(14).height(36).padding({ left: 20, right: 20 })
              .backgroundColor(this.isSaved ? '#4CAF50' : '#FF9800')
              .fontColor('#ffffff').borderRadius(18)
              .margin({ left: 12, top: 8 })
              .onClick(() => {
                this.handleSaveToggle();
              })

            Button('翻译整句')
              .fontSize(14).height(36).padding({ left: 20, right: 20 })
              .backgroundColor(this.sentence.length > 0 ? '#9C27B0' : '#cccccc')
              .fontColor('#ffffff').borderRadius(18)
              .margin({ left: 12, top: 8 })
              .enabled(this.sentence.length > 0)
              .onClick(() => {
                this.handleBatchLookup();
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)

          // Batch lookup results
          if (this.isBatchLoading) {
            Row() {
              LoadingProgress().width(16).height(16).margin({ right: 8 })
              Text('逐词查询中...').fontSize(13).fontColor('#888888')
            }
            .width('100%')
            .margin({ top: 8, bottom: 4 })
          }
          if (this.batchResultItems.length > 0) {
            Column() {
              Text('整句逐词释义:')
                .fontSize(12).fontWeight(FontWeight.Bold).fontColor('#9C27B0')
                .width('100%')
                .margin({ bottom: 6 })
              ForEach(this.batchResultItems, (item: BatchResultItem) => {
                Row() {
                  Text(item.word)
                    .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#333333')
                    .margin({ right: 6 })
                  if (item.phonetic.length > 0) {
                    Text(item.phonetic)
                      .fontSize(12).fontColor('#888888').fontStyle(FontStyle.Italic)
                      .margin({ right: 6 })
                  }
                  Text(item.found ? item.definition : item.definition)
                    .fontSize(13).fontColor(item.found ? '#555555' : '#aaaaaa')
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ top: 4, bottom: 4 })
              }, (item: BatchResultItem): string => item.word)
            }
            .width('100%')
            .padding(8)
            .backgroundColor('#f3e5f5')
            .borderRadius(6)
            .margin({ top: 8, bottom: 4 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
    }
    .padding(20)
    .width('100%')
  }
}
