import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 功能半屏面板（雪白圆角，功能胶囊唤出）。
 */
@Component
export struct ReaderMenuPanel {
  @StorageProp('darkMode') darkMode: boolean = false;
  onClose: () => void = () => {};
  onOpenVocabulary: () => void = () => {};
  onToggleAnnotationPanel: () => void = () => {};
  onExportAnnotations: () => void = () => {};
  onOpenApiConfig: () => void = () => {};

  build() {
    Stack() {
      // 遮罩
      Column().width('100%').height('100%').backgroundColor(ReaderTheme.scrim)
        .position({ top: 0, left: 0 }).onClick(() => { this.onClose(); }).zIndex(101)
      // 面板
      Column() {
        // 拖拽指示条
        Row().width(40).height(4).borderRadius(2).backgroundColor(ReaderTheme.divider).margin({ top: 4, bottom: 8 })
        Scroll() {
          Column() {
            // ── [功能] ──
            Text('功能').fontSize(14).fontWeight(FontWeight.Bold).fontColor(ReaderTheme.textTertiary).margin({ top: 4, bottom: 4 })
            Text('生词本').fontSize(14).fontColor(ReaderTheme.textPrimary).padding({ top: 10, bottom: 10 }).width('100%')
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.onOpenVocabulary();
              })
            Text('批注').fontSize(14).fontColor(ReaderTheme.textPrimary).padding({ top: 10, bottom: 10 }).width('100%')
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.onToggleAnnotationPanel();
              })
            Text('导出批注').fontSize(14).fontColor(ReaderTheme.textPrimary).padding({ top: 10, bottom: 10 }).width('100%')
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.onExportAnnotations();
              })
            Text('词典API设置').fontSize(14).fontColor(ReaderTheme.textPrimary).padding({ top: 10, bottom: 10 }).width('100%')
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                this.onOpenApiConfig();
              })
          }.width('100%')
        }.layoutWeight(1)
      }
      .width('100%').height('50%')
      .backgroundColor(ReaderTheme.bgCard)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .padding(16)
      .position({ bottom: 0 })
      .transition(TransitionEffect.translate({ y: 400 }))
      .zIndex(102)
    }
    .width('100%').height('100%')
  }
}
