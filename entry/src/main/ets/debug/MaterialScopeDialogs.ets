/**
 * MaterialScopeDialogs — 沉浸光感探针 · 弹窗类组件（全区域生效）。
 *
 * 依据官方豁免清单，逐项展示弹窗类组件的用途并可通过按钮打开实测：
 *  AlertDialog / ActionSheet / CustomDialog / TextPickerDialog / DatePickerDialog /
 *  TimePickerDialog / CalendarPickerDialog / AlphabetIndexer 弹窗 /
 *  Text(copyOption) 文本菜单 / SelectionMenu 划词菜单。
 * 各弹窗均显式传入 systemMaterial（厚材质），背景为渐变+条纹便于识别。
 */

import { uiMaterial, SelectionMenu } from '@kit.ArkUI';
import { probeMaterial } from './MaterialScopeCommon.ets';

/** 划词菜单材质：厚玻璃 + 半透明白赋色（磨砂白底，避免纯透明只剩描边） */
function selectionMenuMaterial(): uiMaterial.Material {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THICK,
    materialColor: 'rgba(255,255,255,0.5)',
    colorInvert: false,
    applyShadow: true
  });
}

/** 自定义弹窗内容 */
@CustomDialog
struct ProbeCustomDialog {
  controller?: CustomDialogController;

  build() {
    Column({ space: 12 }) {
      Text('自定义弹窗')
        .fontSize(16).fontWeight(FontWeight.Medium).fontColor('#333333')
      Text('可放任意自定义布局的内容，材质在控制器配置中开启')
        .fontSize(12).fontColor('#666666')
      Button('关闭')
        .fontSize(13)
        .type(ButtonType.Capsule)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding({ left: 18, right: 18, top: 16, bottom: 16 })
  }
}

@Entry
@Component
struct MaterialScopeDialogs {
  private dialogController: CustomDialogController | null = null;

  private alphabetArr: string[] = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L',
    'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];

  aboutToAppear(): void {
    this.dialogController = new CustomDialogController({
      builder: ProbeCustomDialog({}),
      autoCancel: true,
      systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
    });
  }

  aboutToDisappear(): void {
    if (this.dialogController !== null) {
      this.dialogController.close();
      this.dialogController = null;
    }
  }

  /** 条目卡片：名称 + 功能说明 + 打开按钮 */
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

  /** 划词菜单内容（SelectionMenu 组件） */
  @Builder
  selectionMenuBar() {
    SelectionMenu({
      editorMenuOptions: [
        { icon: '✂', action: (): void => {} },
        { icon: '📋', action: (): void => {} }
      ],
      backgroundSystemMaterial: selectionMenuMaterial()
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
          Text('弹窗类组件')
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

        Text('弹窗类组件在页面内任意位置均可渲染沉浸光感，以下逐项实测（厚材质）。')
          .fontSize(12)
          .fontColor('#CCFFFFFF')
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })

        Scroll() {
          Column() {
            this.itemCard('警告弹窗（AlertDialog）', '提示重要信息、让用户确认操作（确定/取消），固定样式不可自定义布局。', (): void => {
              this.getUIContext().showAlertDialog({
                title: '警告弹窗',
                message: '用于需要用户确认的提示信息，可配置按钮。',
                autoCancel: true,
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })
            this.itemCard('操作列表弹窗（ActionSheet）', '从底部弹出多个操作选项供用户选择（如分享/删除/复制）。', (): void => {
              this.getUIContext().showActionSheet({
                title: '操作列表弹窗',
                message: '提供多个选项供选择，每个选项可绑定回调。',
                sheets: [
                  { title: '复制', action: (): void => {} },
                  { title: '分享', action: (): void => {} },
                  { title: '删除', action: (): void => {} }
                ],
                autoCancel: true,
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })
            this.itemCard('自定义弹窗（CustomDialog）', '内容完全自定义，适合表单、复杂互动，材质在控制器配置中开启。', (): void => {
              this.dialogController?.open();
            })
            this.itemCard('文本选择弹窗（TextPickerDialog）', '从一组文本中选择一项（如选择城市/分类）。', (): void => {
              this.getUIContext().showTextPickerDialog({
                range: ['北京', '上海', '广州', '深圳', '杭州'],
                selected: 0,
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })
            this.itemCard('日期选择弹窗（DatePickerDialog）', '选择年、月、日，可配置起止范围。', (): void => {
              this.getUIContext().showDatePickerDialog({
                start: new Date(1990, 0, 1),
                end: new Date(2030, 11, 31),
                selected: new Date(),
                showTime: false,
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })
            this.itemCard('时间选择弹窗（TimePickerDialog）', '选择时分，可切换 12/24 小时制。', (): void => {
              this.getUIContext().showTimePickerDialog({
                selected: new Date(),
                useMilitaryTime: true,
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })
            this.itemCard('日历选择弹窗（CalendarPickerDialog）', '日历视图选日期，适合预订/签到等场景。', (): void => {
              CalendarPickerDialog.show({
                systemMaterial: probeMaterial(uiMaterial.ImmersiveStyle.THICK)
              });
            })

            // 字母索引弹窗（内联展示）
            Row() {
              Column({ space: 4 }) {
                Text('字母索引弹窗（AlphabetIndexer）')
                  .fontSize(15).fontColor('#11232E').fontWeight(FontWeight.Medium)
                Text('右侧字母条，点击字母弹出气泡；常用于联系人/城市列表索引。')
                  .fontSize(12).fontColor('#445566')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              AlphabetIndexer({ arrayValue: this.alphabetArr, selected: 5 })
                .selectedColor('#FFFFFF')
                .popupColor('#FF44336')
                .selectedBackgroundColor('#2679E8')
                .popupBackground('#2679E8')
                .usingPopup(true)
                .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THICK))
                .width(28)
                .height(280)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding(12)
            .borderRadius(14)
            .backgroundColor('#22FFFFFF')
            .margin({ bottom: 8 })
            .alignItems(VerticalAlign.Center)

            // 文本菜单（copyOption 长按，内联展示）
            Text('长按这两行文字：弹出复制/全选等系统文本菜单（copyOption）。')
              .fontSize(14)
              .fontColor('#11232E')
              .fontWeight(FontWeight.Medium)
              .copyOption(CopyOptions.LocalDevice)
              .backgroundColor('#22FFFFFF')
              .borderRadius(14)
              .padding(12)
              .width('100%')
              .margin({ bottom: 8 })

            // 划词菜单（SelectionMenu，长按触发，内联展示）
            Text('长按我：弹出自定义划词菜单（SelectionMenu + 厚材质背景）。')
              .fontSize(14)
              .fontColor('#11232E')
              .fontWeight(FontWeight.Medium)
              .copyOption(CopyOptions.LocalDevice)
              .bindSelectionMenu(TextSpanType.TEXT, this.selectionMenuBar(), TextResponseType.LONG_PRESS)
              .backgroundColor('#22FFFFFF')
              .borderRadius(14)
              .padding(12)
              .width('100%')
              .margin({ bottom: 8 })
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