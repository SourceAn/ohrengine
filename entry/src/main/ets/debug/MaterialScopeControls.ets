/**
 * MaterialScopeControls — 沉浸光感探针 · 按钮与选择类组件（全区域生效）。
 *
 * 官方豁免清单中的「按钮与选择类组件」：
 *  滑杆（Slider）/ 开关（Toggle）/ 下拉选择（Select），在页面内任意位置生效。
 */

import { uiMaterial } from '@kit.ArkUI';
import { probeMaterial } from './MaterialScopeCommon.ets';

@Entry
@Component
struct MaterialScopeControls {
  /** 条目卡片：名称 + 功能说明 */
  @Builder
  itemCard(name: string, desc: string) {
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
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor('#22FFFFFF')
    .margin({ bottom: 8 })
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
          Text('按钮与选择类')
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

        Text('按钮与选择类组件在页面内任意位置均可渲染沉浸光感，以下逐项实测。')
          .fontSize(12)
          .fontColor('#CCFFFFFF')
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 10 })

        Scroll() {
          Column() {
            this.itemCard('滑杆（Slider）', '拖动调节数值。背景可自配成白色胶囊：backgroundColor 白底、trackColor 灰轨、selectedColor 进度色、blockColor 滑块色。')
            // 搭配系统材质：白色胶囊底 + 灰色轨道 + 蓝色进度（ENABLE 模式下材质可能优先于背景色，对照观察）
            Slider({ value: 50, min: 0, max: 100, style: SliderStyle.InSet })
              .backgroundColor('#FFFFFFFF')
              .trackColor('#C0C4CC')
              .selectedColor('#2679E8')
              .blockColor('#FFFFFF')
              .borderRadius(24)
              .height(48)
              .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THIN))
              .width('100%')
              .margin({ bottom: 14 })

            Text('纯样式对照（不开启材质）：与上一支对比，验证系统材质是否覆盖白底。')
              .fontSize(11)
              .fontColor('#AAFFFFFF')
              .width('100%')
              .margin({ bottom: 6 })
            Slider({ value: 50, min: 0, max: 100, style: SliderStyle.InSet })
              .backgroundColor('#FFFFFFFF')
              .trackColor('#C0C4CC')
              .selectedColor('#2679E8')
              .blockColor('#FFFFFF')
              .borderRadius(24)
              .height(48)
              .width('100%')
              .margin({ bottom: 6 })

            this.itemCard('开关（Toggle）', '二态开关切换，常用于设置项的开/关。')
            Row() {
              Toggle({ type: ToggleType.Button, isOn: true }) {
                Text('开启').fontSize(14).fontColor('#333333')
              }
              .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THIN))
            }
            .width('100%')
            .margin({ bottom: 6 })

            this.itemCard('下拉选择（Select）', '点击按钮展开选项列表选择，适合固定选项枚举。')
            Select([
              { value: '小' },
              { value: '中' },
              { value: '大' }
            ])
              .value('点击展开')
              .selected(0)
              .font({ size: 14, weight: FontWeight.Medium })
              .fontColor('#333333')
              .systemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THIN))
              .menuSystemMaterial(probeMaterial(uiMaterial.ImmersiveStyle.THICK))
              .height(44)
              .width('100%')
              .margin({ bottom: 8 })

            Text('说明：这些组件属于「按钮与选择类」白名单，可在页面任意位置获得沉浸光感；应用处于 ENABLE 模式时它们也会默认开启材质。')
              .fontSize(11)
              .fontColor('#AAFFFFFF')
              .width('100%')
              .padding({ left: 6, right: 6, top: 8 })
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