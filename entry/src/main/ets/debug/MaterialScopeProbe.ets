/**
 * MaterialScopeProbe — 沉浸光感可用组件清单 · 分类入口页。
 *
 * 依据官方 26.0.0 生效约束的豁免清单，按分类进入对应的单独探针页：
 *   弹窗类组件 / 弹窗类接口 / 按钮与选择类 / 对照（普通组件）。
 * 背景采用渐变 + 条纹，便于肉眼识别材质是否真实渲染。
 */

@Entry
@Component
struct MaterialScopeProbe {
  /** 分类入口卡片 */
  @Builder
  menuCard(title: string, desc: string, action: () => void) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(16).fontColor('#11232E').fontWeight(FontWeight.Bold)
          .width('100%')
        Text(desc)
          .fontSize(12).fontColor('#445566')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Image($r('sys.media.ohos_ic_public_arrow_right'))
        .width(20).height(20)
        .objectFit(ImageFit.Contain)
        .fillColor('#445566')
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor('#22FFFFFF')
    .margin({ bottom: 10 })
    .onClick(action)
  }

  /** 条纹背景（便于观察玻璃/模糊） */
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

  build() {
    Stack() {
      // 背景：渐变 + 条纹
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
          Text('沉浸光感·可用组件清单')
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

        Text('按官方生效约束的豁免清单分类，各分类独立页面逐项实测。')
          .fontSize(12)
          .fontColor('#DDEeffFF')
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })

        Scroll() {
          Column() {
            this.menuCard('弹窗类组件', '警告弹窗 / 操作列表 / 自定义弹窗 / 四类选择器 / 字母索引弹窗 / 文本菜单 / 划词菜单', (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'debug/MaterialScopeDialogs' });
            })
            this.menuCard('弹窗类接口', '对话框接口 / 气泡弹窗 / 提示气泡 / 菜单控制 / 半模态转场', (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'debug/MaterialScopeInterfaces' });
            })
            this.menuCard('按钮与选择类', '滑杆 / 开关 / 下拉选择（白名单组件）', (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'debug/MaterialScopeControls' });
            })
            this.menuCard('对照·普通组件', '行 / 列 / 按钮在页面普通位置（按约束预期不生效）', (): void => {
              this.getUIContext().getRouter().pushUrl({ url: 'debug/MaterialScopeContrast' });
            })

            Text('说明：弹窗类组件与接口、按钮与选择类（滑杆/开关/下拉选择）在页面内全部区域生效；普通组件仅在顶部标题栏或底部页签区域生效。')
              .fontSize(11)
              .fontColor('#AAFFFFFF')
              .width('100%')
              .padding({ left: 6, right: 6, top: 12 })
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