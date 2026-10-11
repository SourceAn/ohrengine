import { AnnotationType } from 'ohrengine-common';
import type { Annotation } from 'ohrengine-common';
import { IconAssets } from '../common/IconAssets.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 标注面板（列表 + 导出 + 删除）。
 */
@Component
export struct AnnotationPanel {
  @StorageProp('darkMode') darkMode: boolean = false;
  @Prop annotations: Annotation[] = [];
  onDelete: (ann: Annotation) => void = () => {};
  onExport: (format: string) => void = () => {};
  onClose: () => void = () => {};

  build() {
    Column() {
      Text('标注 (' + this.annotations.length + ')').fontSize(18).fontWeight(FontWeight.Bold).margin({ bottom: 8 })
      Scroll() {
        Column() {
          if (this.annotations.length === 0) {
            Text('暂无标注').fontSize(14).fontColor(ReaderTheme.textTertiary).padding(16)
          }
          ForEach(this.annotations, (ann: Annotation) => {
            Row({ space: 6 }) {
              Circle().width(10).height(10)
                .fill(ann.type === AnnotationType.HIGHLIGHT ? '#FFD700'
                  : ann.type === AnnotationType.UNDERLINE ? '#FF6B35' : '#0078D4')
              Text(ann.text !== undefined && ann.text.length > 40
                ? ann.text.substring(0, 40) + '...' : (ann.text ?? ''))
                .fontSize(13).fontColor(ReaderTheme.textPrimary).layoutWeight(1)
              Button() {
                Image(IconAssets.delete())
                  .width(14).height(14)
                  .objectFit(ImageFit.Contain)
                  .fillColor('#ff4444')
              }
                .height(24).width(24).backgroundColor(this.darkMode ? '#333539' : '#fff')
                .onClick(() => {
                  this.onDelete(ann);
                })
            }.padding({ top: 4, bottom: 4 })
          })
        }.width('100%')
      }.layoutWeight(1)
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Button('JSON').fontSize(12).onClick(() => {
            this.onExport('json');
          })
          Button('Markdown').fontSize(12).onClick(() => {
            this.onExport('markdown');
          })
          Button('CSV').fontSize(12).onClick(() => {
            this.onExport('csv');
          })
          Button('HTML').fontSize(12).onClick(() => {
            this.onExport('html');
          })
        }.justifyContent(FlexAlign.Center)
        Button('关闭').fontSize(12).width(80).onClick(() => {
          this.onClose();
        }).alignSelf(ItemAlign.Center)
      }.margin({ top: 8 })
    }
    .width(300).height(400)
    .backgroundColor(ReaderTheme.bgCard)
    .borderRadius(16).padding(16)
    .shadow({ radius: 10 })
    .position({ x: '30%', y: '15%' })
    .zIndex(101)
  }
}
