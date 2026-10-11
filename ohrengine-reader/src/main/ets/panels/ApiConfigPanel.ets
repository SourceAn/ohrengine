/**
 * 在线词典 API 设置弹窗（独立居中卡片）。
 */
import { ReaderTheme } from '../common/ReaderTheme.ets';

@Component
export struct ApiConfigPanel {
  @StorageProp('darkMode') darkMode: boolean = false;
  @Prop apiConfigName: string = '';
  @Prop apiConfigEndpoint: string = '';
  @Prop apiConfigMessage: string = '';
  onNameChange: (val: string) => void = () => {};
  onEndpointChange: (val: string) => void = () => {};
  onAdd: () => void = () => {};
  onClose: () => void = () => {};

  build() {
    Stack() {
      // 遮罩
      Column().width('100%').height('100%').backgroundColor(ReaderTheme.scrim)
        .position({ top: 0, left: 0 }).onClick(() => { this.onClose(); }).zIndex(101)
      // 弹窗卡片 — 水平垂直居中
      Column() {
        Text('在线词典 API').fontSize(18).fontWeight(FontWeight.Bold).margin({ bottom: 16 })
        TextInput({ placeholder: 'API 名称（如 MyDict）', text: this.apiConfigName })
          .width('100%').height(32).fontSize(12)
          .onChange((val: string) => { this.onNameChange(val); })
        TextInput({ placeholder: 'https://example.com/api/{word}', text: this.apiConfigEndpoint })
          .width('100%').height(32).fontSize(12).margin({ top: 6 })
          .onChange((val: string) => { this.onEndpointChange(val); })
        Row({ space: 8 }) {
          Button('添加').fontSize(12).fontColor('#ffffff').backgroundColor(ReaderTheme.accent)
            .enabled(this.apiConfigName.length > 0 && this.apiConfigEndpoint.length > 0)
            .onClick(() => {
              this.onAdd();
            })
          if (this.apiConfigMessage.length > 0) {
            Text(this.apiConfigMessage).fontSize(11).fontColor('#4CAF50')
          }
        }.alignItems(VerticalAlign.Center).margin({ top: 6 })
        // Show registered providers
        Text('已注册: Builtin, FreeDictionaryAPI (加上自定义)')
          .fontSize(10).fontColor(ReaderTheme.textTertiary).margin({ top: 4 })
        Button('关闭').fontSize(12).width(80).margin({ top: 16 })
          .onClick(() => {
            this.onClose();
          })
      }
      .width(300)
      .backgroundColor(ReaderTheme.bgCard)
      .borderRadius(16).padding(20)
      .shadow({ radius: 12 })
      .position({ top: '50%', left: '50%' })
      .translate({ x: -150, y: -70 })
      .zIndex(102)
    }
    .width('100%').height('100%')
  }
}
