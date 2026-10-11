/**
 * VocabularyListPage - Saved vocabulary list page
 *
 * Displays all words saved to the vocabulary book with word, phonetic,
 * definition, and save date. Supports swipe-to-delete.
 *
 * Navigation: Index.ets calls setVocabularyPageEngine() then router.pushUrl.
 * Engine reference is held at module level (router cannot pass objects).
 */

import { VocabularyItem } from 'ohrengine-feature';
import { OhEngine } from 'ohrengine-ui-render';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

// ── Module-level engine reference (router cannot pass object references) ──
let _pageEngine: OhEngine | undefined = undefined;

/**
 * Set the engine instance before pushing this page.
 */
export function setVocabularyPageEngine(e: OhEngine): void {
  _pageEngine = e;
}

@Entry
@Component
struct VocabularyListPage {
  @State vocabulary: VocabularyItem[] = [];
  @State isLoading: boolean = true;

  aboutToAppear(): void {
    this.loadVocabulary();
  }

  private loadVocabulary(): void {
    this.isLoading = true;
    if (_pageEngine === undefined) {
      this.vocabulary = [];
      this.isLoading = false;
      return;
    }
    this.vocabulary = _pageEngine.getVocabulary();
    this.isLoading = false;
  }

  private async deleteWord(word: string): Promise<void> {
    if (_pageEngine === undefined) {
      return;
    }
    try {
      await _pageEngine.removeWordFromVocabulary(word);
      // Refresh list after deletion
      this.vocabulary = _pageEngine.getVocabulary();
    } catch (err) {
    }
  }

  /** Export vocabulary as CSV and save to device */
  private async handleExportCsv(): Promise<void> {
    if (_pageEngine === undefined) {
      return;
    }
    try {
      const csvContent: string = await _pageEngine.exportVocabularyAsCsv();
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      const filePath: string = context.filesDir + '/vocabulary_export.csv';
      const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, csvContent);
      fileIo.closeSync(file);
    } catch (err) {
    }
  }

  /**
   * Format a Unix timestamp (ms) to a readable date string (YYYY-MM-DD).
   */
  private formatDate(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const year: string = date.getFullYear().toString();
    const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
    const day: string = date.getDate().toString().padStart(2, '0');
    return year + '-' + month + '-' + day;
  }

  build(): void {
    Column() {
      // ── Header ──
      Row() {
        Button('< Back')
          .fontSize(14).height(36).padding({ left: 12, right: 12 })
          .backgroundColor('#0078D4').fontColor('#ffffff').borderRadius(18)
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })
        Text('Vocabulary Book')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1a1a1a')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Button('Export CSV')
          .fontSize(14).height(36).padding({ left: 12, right: 12 })
          .backgroundColor('#4CAF50').fontColor('#ffffff').borderRadius(18)
          .onClick(() => {
            this.handleExportCsv();
          })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor('#f5f5f5')

      if (this.isLoading) {
        // Loading state
        LoadingProgress()
          .width(32).height(32).margin({ top: 60, bottom: 40 })
        Text('Loading vocabulary...').fontSize(14).fontColor('#888888')
      } else if (this.vocabulary.length === 0) {
        // Empty state
        Column() {
          Text('[ Vocab ]')
            .fontSize(36).fontColor('#cccccc').margin({ top: 60, bottom: 16 })
          Text('No saved vocabulary yet.')
            .fontSize(16).fontColor('#888888')
          Text('Look up a word and tap "Save" to add it here.')
            .fontSize(14).fontColor('#aaaaaa')
            .margin({ top: 8 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      } else {
        // ── Vocabulary list with swipe-to-delete ──
        List() {
          ForEach(this.vocabulary, (item: VocabularyItem) => {
            ListItem() {
              // Vocabulary card
              Row() {
                Column() {
                  Text(item.word)
                    .fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1a1a1a')
                    .width('100%')
                  if (item.phonetic.length > 0) {
                    Text('/' + item.phonetic + '/')
                      .fontSize(13).fontColor('#888888').fontStyle(FontStyle.Italic)
                      .width('100%')
                      .margin({ top: 2 })
                  }
                  Text(item.definition)
                    .fontSize(14).fontColor('#555555')
                    .width('100%')
                    .margin({ top: 4 })
                    .maxLines(2)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text(this.formatDate(item.savedAt))
                  .fontSize(11).fontColor('#aaaaaa')
                  .margin({ left: 8 })
              }
              .width('100%')
              .padding(16)
              .backgroundColor('#ffffff')
              .borderRadius(8)
            }
            .swipeAction({
              end: () => {
                this.deleteButton(item)
              }
            })
            .margin({ left: 16, right: 16, bottom: 8 })
          }, (item: VocabularyItem) => item.word)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#f0f0f0')
  }

  @Builder
  deleteButton(item: VocabularyItem) {
    Column() {
      Button('Delete')
        .fontSize(14).height('100%').width(72)
        .backgroundColor('#ff4444').fontColor('#ffffff')
        .borderRadius(0)
        .onClick(() => {
          this.deleteWord(item.word);
        })
    }
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
