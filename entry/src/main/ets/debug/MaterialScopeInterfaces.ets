/**
 * MaterialScopeInterfaces — 沉浸光感探针 · 弹窗类接口（全区域生效）。
 *
 * 依据官方豁免清单，逐项展示弹窗类接口的用途并实测：
 *  PromptAction 对话框 / Popup 控制 / Tips 控制 / 菜单控制 / 半模态转场（bindSheet）。
 */

import { uiMaterial } from '@kit.ArkUI';
import { probeMaterial } from './MaterialScopeCommon.ets';

/** 菜单内容（全局 @Builder，避免 this 丢失） */
@Builder
function probeMenuContent() {
  Column({ space: 2 }) {
    Text('打开')
      .fontSize(13).fontColor('#333333').padding({ left: 12, right: 12, top: 8, bottom: 8 })
    Text('复制')
      .fontSize(13).fontColor('#333333').padding({ left: 12, right: 12, top: 8, bottom: 8 })
    Text('删除')
      .fontSize(13).fontColor('#FF44336').padding({ left: 12, right: 12, top: 8, bottom: 8 })
  }
}

@Entry
@Component
struct MaterialScopeInterfaces {
  @State popupShow: boolean = false;
  @State sheetShow: boolean = false;

  /** 条目卡片 */
  @Builder
  itemCard(name: string, desc: string, action: () => void) {
    Row() {
      Column({ space: 3 }) {
        Text(name)
          .fontSize(15).fontColor('#11232E').fontWeight(FontWeight.Medium)
          .width('100%')
        Text(desc)
          .fontSize(12).fontColor('#445566')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Button('打开')
        .fontSize(13)
        .height(34)
        .type(ButtonType.Capsule)
        .backgroundColor('#2679E8')
        .margin({ left: 8 })
        .onClick(action)
    }
    .width('100%')
    .padding(12)
    .borderRadius(14)
    .backgroundColor('#22FFFFFF')
    .margin({ bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /** 条纹背景 */
  @Builder
  stripeBg() {
    Column() {
      ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19], (i: number) => {
        Row()
          .width('100%')
          .height(34)
          .backgroundColor(i % 2 === 0 ? '#33FFFFFF' : '#33000000')
      }, (i: number): string => 's_' + i)
    }
    .width('100%')
    .height('100%')
  }

  /** 半模态内容 */
  @Builder
  sheetContent() {
    Column({ space: 10 }) {
      Text('半模态转场（bindSheet）')
        .fontSize(16).fontColor('#333333').fontWeight(FontWeight.Medium)
      Text('从底部滑出的半屏面板，适合设置/详情等二级内容')
        .fontSize(12).fontColor('#666666')
      Button('关闭')
        .fontSize(13)
        .type(ButtonType.Capsule)
        .onClick(() => {
          this.sheetShow = false;
        })
    }
    .padding(20)
  }

  /** 半模态宿主（悬浮空容器） */
  @Builder
  sheetHost() {
    Column() {
    }
    .width('100%')
    .height(1)
    .hitTestBehavior(HitTestMode.None)
    .bindSheet($$this.sheetShow, this.sheetContent(), {
      height: 240,
      mode: SheetMode.OVERLAY,
      systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THIN)
    })
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [
            ['#004AAF', 0.0],
            ['#2787D9', 0.5],
            ['#F0FAFF', 1.0]
          ]
        })
      this.stripeBg()

      Column() {
        Row() {
          Text('弹窗类接口')
            .fontSize(20).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
          Blank()
          Button('返回')
            .fontSize(13)
            .height(34)
            .backgroundColor('#66000000')
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        Text('弹窗类接口在页面内任意位置均可渲染沉浸光感，以下逐项实测。')
          .fontSize(12)
          .fontColor('#CCFFFFFF')
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })

        Scroll() {
          Column() {
            this.itemCard('对话框接口（PromptAction）', '系统级对话框接口，可弹提示/确认/自定义对话框，适合轻量询问。', (): void => {
              this.getUIContext().getPromptAction().showDialog({
                title: '对话框接口',
                message: '提示内容',
                buttons: [{ text: '取消', color: '#666666' }, { text: '确定', color: '#2679E8' }],
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })

            this.itemCard('气泡弹窗（Popup 控制）', '在锚点组件四周弹出气泡，适合角标提示、快捷操作。', (): void => {
              this.popupShow = true;
            })
            // Popup 锚点（内联承载）
            Row() {
              Text('Popup 锚点（点击弹出）')
                .fontSize(14).fontColor('#FFFFFF')
            }
            .justifyContent(FlexAlign.Center)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor('#22FFFFFF')
            .borderRadius(14)
            .margin({ left: 12, bottom: 10 })
            .bindPopup(this.popupShow, {
              message: '气泡弹窗（Popup）：本机实测材质不渲染（S.7 结论），builder 形式可能崩溃，故用 message 形式演示',
              placement: Placement.Top,
              systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THIN)
            } as PopupOptions)
            .onClick(() => {
              this.popupShow = true;
            })

            this.itemCard('提示气泡（Tips 控制）', '仅鼠标悬停时显示提示（触屏无悬停，点击不出气泡属正常）。', (): void => {
            })
            // Tips 锚点（内联承载）
            Row() {
              Text('Tips 锚点（悬停显示提示）')
                .fontSize(14).fontColor('#FFFFFF')
            }
            .justifyContent(FlexAlign.Center)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor('#22FFFFFF')
            .borderRadius(14)
            .margin({ left: 12, bottom: 10 })
            .bindTips('这是 Tips 提示气泡（需悬停触发）', {
              systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THIN)
            } as TipsOptions)

            this.itemCard('菜单控制（菜单控制）', '点击弹出菜单列表（bindMenu），适合更多操作入口。', (): void => {
            })
            // 菜单锚点（内联承载）
            Row() {
              Text('bindMenu 锚点（点击弹出）')
                .fontSize(14).fontColor('#FFFFFF')
            }
            .justifyContent(FlexAlign.Center)
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor('#22FFFFFF')
            .borderRadius(14)
            .margin({ left: 12, bottom: 10 })
            .bindMenu(probeMenuContent, {
              systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
            } as MenuOptions)

            this.itemCard('半模态转场（bindSheet）', '从底部滑出半屏面板，适合设置/详情等二级内容。', (): void => {
              this.sheetShow = true;
            })

            this.sheetHost()
          }
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 40 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}