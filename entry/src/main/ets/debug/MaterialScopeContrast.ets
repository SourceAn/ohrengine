/**
 * MaterialScopeContrast — 沉浸光感探针 · 对照区（普通组件）。
 *
 * 按官方生效约束：普通组件（行/列/按钮等）仅在 Navigation/NavDestination 标题栏、
 * 底部页签（Tabs barPosition=End）中生效；页面普通位置设置系统材质预期不渲染。
 * 本页用于对照验证。
 */

import { uiMaterial } from '@kit.ArkUI';
import { probeMaterial } from './MaterialScopeCommon.ets';

@Entry
@Component
struct MaterialScopeContrast {
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
          Text('对照·普通组件')
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

        Text('按官方约束，以下普通组件在页面普通位置设置系统材质预期不生效（无玻璃效果）。')
          .fontSize(12)
          .fontColor('#CCFFFFFF')
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })

        Scroll() {
          Column({ space: 10 }) {
            Row() {
              Text('行容器（Row）+ 薄材质')
                .fontSize(13).fontColor('#333333')
            }
            .width(240).height(48).borderRadius(24)
            .justifyContent(FlexAlign.Center)
            .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THIN))

            Column() {
              Text('列容器（Column）+ 薄材质')
                .fontSize(13).fontColor('#333333')
            }
            .width(240).height(48).borderRadius(24)
            .justifyContent(FlexAlign.Center)
            .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THIN))

            Button('按钮（Button）+ 薄材质')
              .fontSize(13).fontColor('#333333')
              .width(240).height(48).type(ButtonType.Capsule)
              .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THIN))

            Text('说明：这些普通组件的材质只有在顶部标题栏或底部页签区域才会生效；若与白名单组件（滑杆/开关/下拉选择）对比，应能看到明显差异。')
              .fontSize(11)
              .fontColor('#AAFFFFFF')
              .width('100%')
              .padding({ left: 6, right: 6, top: 8 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
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