/**
 * HdsMaterialHostPoc — Phase S.6 临时 POC（验证完成后删除）
 *
 * 统一被测组件 ReaderControlMock（模拟真实阅读器 UI），
 * 分别放入 Sheet / AlertDialog / Popup / ContextMenu 四种 Material Host 验证承载能力。
 */

import { uiMaterial, componentSnapshot } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { effectKit } from '@kit.ArkGraphics2D';
import { SegmentButton, SegmentButtonOptions } from '@ohos.arkui.advanced.SegmentButton';
import { Chip } from '@ohos.arkui.advanced.Chip';
import { image } from '@kit.ImageKit';

const TAG: string = 'HdsHost';
const DOMAIN: number = 0x0053;

type PocBgKind = 'gradient' | 'colorful' | 'dark';

class Env6 {
  static stripe(k: PocBgKind): string {
    if (k === 'dark') {
      return '#59FFFFFF';
    }
    return '#4D000000';
  }

  static microText(k: PocBgKind): string {
    if (k === 'dark') {
      return '#8CFFFFFF';
    }
    return '#B3000000';
  }
}

function thinMaterial(): uiMaterial.Material {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    materialColor: 'rgba(255,255,255,0.06)',
    colorInvert: false,
    applyShadow: true,
    interactive: false,
    lightEffect: { color: undefined }
  });
}

@Builder
function emptyBuilder() {
}

/**
 * Popup builder 必须用全局 @Builder：组件方法传递后 this 丢失会崩溃
 * （TypeError: observeComponentCreation2 of undefined）。
 */
@Builder
function popupBuilderGlobal() {
  Column({ space: 8 }) {
    Text('HC Popup Host')
      .fontSize(11)
      .fontColor('#FF333333')
      .fontWeight(FontWeight.Bold)
    Row({ space: 10 }) {
      Row() {
        Text('‹').fontSize(20).fontColor('#4A4F55')
      }
      .width(44).height(44).borderRadius(22).justifyContent(FlexAlign.Center)
      Row() {
        Text('☰').fontSize(20).fontColor('#4A4F55')
      }
      .width(44).height(44).borderRadius(22).justifyContent(FlexAlign.Center)
    }
  }
  .padding(10)
}

@Entry
@Component
struct HdsMaterialHostPoc {
  @State bgKind: PocBgKind = 'gradient';
  @State infoLine: string = '';
  @State showMockSheet: boolean = false;
  @State clean: boolean = false;
  @State caseKind: string = '';
  @State v2PixelMap: image.PixelMap | undefined = undefined;
  @State v2Busy: boolean = false;
  @State showPopup: boolean = false;
  @State showMsgPopup: boolean = false;
  private stripeIdx: number[] = [];

  aboutToAppear(): void {
    for (let i: number = 0; i < 70; i++) {
      this.stripeIdx.push(i);
    }
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      hilog.info(DOMAIN, TAG, 'host state=%{public}d type=%{public}d', info.state, info.type);
      this.infoLine = 'state=' + info.state + ' api=' + deviceInfo.sdkApiVersion;
    } catch (err) {
      this.infoLine = 'materialInfo failed';
    }
    // Case 来源：优先 router params（调试书架按钮进入），兼容 AppStorage（aa start 注入）
    const routerParams = this.getUIContext().getRouter().getParams() as Record<string, Object> | undefined;
    const autoCase: string | undefined =
      (routerParams?.['pocCase'] as string | undefined) ?? AppStorage.get<string>('pocCase');
    const autoBg: string | undefined =
      (routerParams?.['pocBg'] as string | undefined) ?? AppStorage.get<string>('pocBg');
    this.caseKind = autoCase ?? '';
    if (autoBg === 'colorful') {
      this.bgKind = 'colorful';
    } else if (autoBg === 'dark') {
      this.bgKind = 'dark';
    }
    if (autoCase !== undefined && autoCase !== 'base') {
      setTimeout((): void => {
        this.openCase(autoCase);
      }, 900);
    }
  }

  private openCase(name: string): void {
    hilog.info(DOMAIN, TAG, 'open %{public}s', name);
    if (name === 'HA') {
      this.showMockSheet = true;
    } else if (name === 'HB') {
      AlertDialog.show({
        message: 'HB AlertDialog Host：双版本无 builder，仅文本+按钮',
        autoCancel: true,
        systemMaterial: thinMaterial()
      });
    } else if (name === 'HC') {
      this.showPopup = true;
      this.showMsgPopup = true;
    }
  }

  // ─────────────── 统一被测组件：ReaderControlMock ───────────────

  @Builder
  mockRound(glyph: string) {
    Row() {
      Text(glyph)
        .fontSize(20)
        .fontColor('#E6E8EB')
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#00000000')
  }

  @Builder
  pocReaderControlMock() {
    Column({ space: 12 }) {
      // 顶部导航行（圆钮用自制材质，与右上角系统关闭钮同屏对照）
      Row() {
        this.fakeGlassRound('‹', this.bgKind === 'dark')
        Text('第七章 · 山雨欲来')
          .fontSize(14)
          .fontColor('#E6E8EB')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        this.fakeGlassRound('☰', this.bgKind === 'dark')
      }
      .width('100%')

      // 阅读进度
      Row({ space: 10 }) {
        Text('42%')
          .fontSize(11)
          .fontColor('#B4BAC1')
        Slider({ value: 42, min: 0, max: 100, style: SliderStyle.OutSet })
          .layoutWeight(1)
          .height(30)
      }
      .width('100%')

      // 功能胶囊行
      Row({ space: 10 }) {
        Button('目录')
          .fontSize(12)
          .height(32)
          .type(ButtonType.Capsule)
        Button('夜间')
          .fontSize(12)
          .height(32)
          .type(ButtonType.Capsule)
        Button('设置')
          .fontSize(12)
          .height(32)
          .type(ButtonType.Capsule)
        Button('朗读')
          .fontSize(12)
          .height(32)
          .type(ButtonType.Capsule)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)

      // 设置卡片
      Column({ space: 6 }) {
        Row() {
          Text('字体')
            .fontSize(12)
            .fontColor('#B4BAC1')
          Blank()
          Text('宋体 · 18')
            .fontSize(12)
            .fontColor('#E6E8EB')
        }
        .width('100%')
        Row() {
          Text('行距')
            .fontSize(12)
            .fontColor('#B4BAC1')
          Blank()
          Text('标准')
            .fontSize(12)
            .fontColor('#E6E8EB')
        }
        .width('100%')
      }
      .width('100%')
      .padding(12)
      .borderRadius(12)
      .border({ width: 1, color: '#33FFFFFF' })

      // TOC 列表
      Column({ space: 8 }) {
        Text('第一章 · 序')
          .fontSize(13)
          .fontColor('#E6E8EB')
          .width('100%')
        Text('第二章 · 入城')
          .fontSize(13)
          .fontColor('#B4BAC1')
          .width('100%')
        Text('第三章 · 山雨欲来')
          .fontSize(13)
          .fontColor('#B4BAC1')
          .width('100%')
      }
      .width('100%')
      .padding(10)
      .borderRadius(12)
      .border({ width: 1, color: '#26FFFFFF' })
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 14, bottom: 14 })
  }

  // ─────────────── 自制材质组件（复刻系统关闭钮特征，不依赖 systemMaterial）───────────────

  /**
   * 参考系：Sheet 系统关闭钮（showClose）的视觉构成：
   * 1. 渐变高光边缘环（上缘最亮）  2. 内凹 blur 面  3. 顶部内侧反光  4. 底部投影  5. 深浅自适应。
   * 用 backdropBlur + 渐变描边层 + 高光层纯 ArkUI 复刻，任何组件可用。
   */
  @Builder
  fakeGlassRound(glyph: string, dark: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      // 1) 渐变高光边缘环（最底层，稍大）
      Column()
        .width(46)
        .height(46)
        .borderRadius(23)
        .linearGradient({
          angle: 160,
          colors: dark
            ? [['#66FFFFFF', 0], ['#1AFFFFFF', 0.4], ['#0DFFFFFF', 0.7], ['#4DFFFFFF', 1]]
            : [['#CCFFFFFF', 0], ['#33FFFFFF', 0.45], ['#14FFFFFF', 0.7], ['#80FFFFFF', 1]]
        })
      // 2) 内凹 blur 面（内缩形成环宽）
      Stack({ alignContent: Alignment.Center }) {
        // 3) 顶部内侧反光
        Column()
          .width(41)
          .height(16)
          .borderRadius({ topLeft: 20.5, topRight: 20.5 })
          .linearGradient({
            angle: 180,
            colors: dark ? [['#26FFFFFF', 0], ['#00FFFFFF', 1]] : [['#4DFFFFFF', 0], ['#00FFFFFF', 1]]
          })
        Text(glyph)
          .fontSize(20)
          .fontColor(dark ? '#E6E8EB' : '#4A4F55')
      }
      .width(42)
      .height(42)
      .borderRadius(21)
      .backgroundBlurStyle(BlurStyle.BACKGROUND_REGULAR)
      .backgroundColor(dark ? '#0FFFFFFF' : '#33FFFFFF')
    }
    .shadow({ radius: 6, color: dark ? '#4D000000' : '#26000000', offsetY: 2 })
  }

  /** 自制玻璃胶囊按钮 */
  @Builder
  fakeGlassCapsule(label: string, dark: boolean) {
    Stack() {
      Column()
        .width('100%')
        .height(34)
        .borderRadius(17)
        .linearGradient({
          angle: 160,
          colors: dark
            ? [['#59FFFFFF', 0], ['#14FFFFFF', 0.5], ['#4DFFFFFF', 1]]
            : [['#B3FFFFFF', 0], ['#26FFFFFF', 0.5], ['#73FFFFFF', 1]]
        })
      Row() {
        Text(label)
          .fontSize(12)
          .fontColor(dark ? '#E6E8EB' : '#3A4046')
      }
      .width('100%')
      .height(32)
      .borderRadius(16)
      .backgroundBlurStyle(BlurStyle.BACKGROUND_REGULAR)
      .backgroundColor(dark ? '#0FFFFFFF' : '#33FFFFFF')
      .justifyContent(FlexAlign.Center)
    }
    .shadow({ radius: 5, color: dark ? '#4D000000' : '#26000000', offsetY: 2 })
  }

  /** 自制玻璃设置卡 */
  @Builder
  fakeGlassCard(dark: boolean) {
    Stack() {
      Column()
        .width('100%')
        .height(88)
        .borderRadius(14)
        .linearGradient({
          angle: 160,
          colors: dark
            ? [['#40FFFFFF', 0], ['#0DFFFFFF', 0.5], ['#26FFFFFF', 1]]
            : [['#99FFFFFF', 0], ['#14FFFFFF', 0.5], ['#4DFFFFFF', 1]]
        })
      Column({ space: 6 }) {
        Row() {
          Text('字体')
            .fontSize(12)
            .fontColor(dark ? '#B4BAC1' : '#6B7076')
          Blank()
          Text('宋体 · 18')
            .fontSize(12)
            .fontColor(dark ? '#E6E8EB' : '#2A2E33')
        }
        .width('100%')
        Row() {
          Text('行距')
            .fontSize(12)
            .fontColor(dark ? '#B4BAC1' : '#6B7076')
          Blank()
          Text('标准')
            .fontSize(12)
            .fontColor(dark ? '#E6E8EB' : '#2A2E33')
        }
        .width('100%')
      }
      .padding(12)
      .width('100%')
      .height(85)
      .borderRadius(13)
      .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
      .backgroundColor(dark ? '#0FFFFFFF' : '#2EFFFFFF')
      .alignItems(HorizontalAlign.Start)
    }
    .shadow({ radius: 8, color: dark ? '#4D000000' : '#26000000', offsetY: 3 })
  }

  /** 自制材质对照区：页面级（无系统容器借宿）同排展示 */
  @Builder
  pocFakeMaterialRow() {
    Column({ space: 8 }) {
      Text('自制材质（复刻系统关闭钮特征，页面级无 Host 场景）')
        .fontSize(11)
        .fontColor('#FFFFFFFF')
        .fontWeight(FontWeight.Bold)
      Row({ space: 16 }) {
        this.fakeGlassRound('‹', this.bgKind === 'dark')
        this.fakeGlassRound('☰', this.bgKind === 'dark')
        this.fakeGlassCapsule('目录', this.bgKind === 'dark')
        this.fakeGlassCapsule('设置', this.bgKind === 'dark')
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      this.fakeGlassCard(this.bgKind === 'dark')
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .margin({ top: 12 })
  }

  // ─────────────── Popup / ContextMenu 内容 ───────────────

  @Builder
  popupBuilder() {
    Column({ space: 8 }) {
      Text('HC Popup Host')
        .fontSize(11)
        .fontColor('#FF333333')
        .fontWeight(FontWeight.Bold)
      Row({ space: 10 }) {
        this.mockRound('‹')
        this.mockRound('☰')
        Button('菜单')
          .fontSize(11)
          .height(28)
          .type(ButtonType.Capsule)
      }
    }
    .padding(10)
  }

  @Builder
  menuBuilder() {
    Column() {
      Text('HD ContextMenu Host')
        .fontSize(12)
        .fontColor('#E6E8EB')
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      Text('复制 · 批注 · 翻译')
        .fontSize(11)
        .fontColor('#B4BAC1')
        .padding({ left: 14, right: 14, bottom: 8 })
    }
    .borderRadius(12)
  }

  // ─────────────── 背景 ───────────────

  @Builder
  pocBackground() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 135,
        colors: this.bgKind === 'gradient'
          ? [['#FF5B6BFF', 0], ['#FFFF6B9D', 0.5], ['#FF4FACFE', 1]]
          : (this.bgKind === 'colorful'
            ? [['#FFFF7A18', 0], ['#FFFF3D77', 1]]
            : [['#FF101014', 0], ['#FF2A2A33', 1]])
      })

      Row() {
        ForEach(this.stripeIdx, (i: number) => {
          Column()
            .width(6)
            .height('100%')
            .backgroundColor(i % 2 === 0 ? Env6.stripe(this.bgKind) : '#00000000')
        }, (i: number) => i.toString())
      }
      .width('100%')
      .height('100%')

      Column() {
        ForEach(this.stripeIdx, (i: number) => {
          Text('HOST ' + i + ' 材质宿主高频采样 ABCabc0123')
            .fontSize(9)
            .fontColor(Env6.microText(this.bgKind))
            .width('100%')
            .height(18)
        }, (i: number) => 't' + i.toString())
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  pocFakeMaterialRow2() {
    Column({ space: 8 }) {
      Text('自制材质（复刻系统关闭钮特征，页面级无 Host 场景）')
        .fontSize(11).fontColor('#FFFFFFFF').fontWeight(FontWeight.Bold)
      Row({ space: 16 }) {
        this.fakeGlassRound('‹', this.bgKind === 'dark')
        this.fakeGlassRound('☰', this.bgKind === 'dark')
        this.fakeGlassCapsule('目录', this.bgKind === 'dark')
        this.fakeGlassCapsule('设置', this.bgKind === 'dark')
      }
      .justifyContent(FlexAlign.Center).width('100%')
      this.fakeGlassCard(this.bgKind === 'dark')
    }
    .width('100%').padding({ left: 16, right: 16 }).margin({ top: 12 })
  }


  // ── V2：快照 vibrancy 管线 ──

  async buildV2Material(): Promise<void> {
    if (this.v2Busy) {
      return;
    }
    this.v2Busy = true;
    try {
      const snapOpts: componentSnapshot.SnapshotOptions = {
        region: { left: 0, top: 300, right: 1276, bottom: 800 },
        scale: 1
      };
      const pm: image.PixelMap = await componentSnapshot.get('pocBgLayer', snapOpts);
      const eff: effectKit.Filter = effectKit.createEffect(pm);
      const processed: image.PixelMap = await eff.blur(60).brightness(1.35).getEffectPixelMap();
      this.v2PixelMap = processed;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'V2 failed: %{public}s', JSON.stringify(e));
    }
    this.v2Busy = false;
  }

  @Builder
  pocV2Panel() {
    Column({ space: 8 }) {
      Text('V2 快照 vibrancy 材质（EffectKit blur+brightness）')
        .fontSize(11)
        .fontColor('#FFFFFFFF')
        .fontWeight(FontWeight.Bold)
      Stack() {
        Column()
          .width('100%').height(206).borderRadius(16)
          .linearGradient({
            angle: 160,
            colors: this.bgKind === 'dark'
              ? [['#66FFFFFF', 0], ['#1AFFFFFF', 0.5], ['#4DFFFFFF', 1]]
              : [['#B3FFFFFF', 0], ['#26FFFFFF', 0.5], ['#80FFFFFF', 1]]
          })
        Stack() {
          if (this.v2PixelMap) {
            Image(this.v2PixelMap)
              .width('100%').height(200).borderRadius(15).objectFit(ImageFit.Cover)
          } else {
            Column() {
              Text(this.v2Busy ? '生成中…' : '点下方按钮生成')
                .fontSize(12)
                .fontColor(this.bgKind === 'dark' ? '#B4BAC1' : '#5A5F66')
            }
            .width('100%').height(200).borderRadius(15)
            .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK)
          }
          Column()
            .width('100%').height(70)
            .borderRadius({ topLeft: 15, topRight: 15 })
            .linearGradient({
              angle: 180,
              colors: this.bgKind === 'dark' ? [['#26FFFFFF', 0], ['#00FFFFFF', 1]] : [['#59FFFFFF', 0], ['#00FFFFFF', 1]]
            })
          Row({ space: 10 }) {
            Text('材质层 V2').fontSize(14).fontColor(this.bgKind === 'dark' ? '#E6E8EB' : '#2A2E33').fontWeight(FontWeight.Bold)
            Text('真背景采样 · blur+vibrancy').fontSize(11).fontColor(this.bgKind === 'dark' ? '#B4BAC1' : '#5A5F66')
          }
          .width('100%').padding(14)
        }
        .width('100%').height(200).borderRadius(15).clip(true)
      }
      .shadow({ radius: 10, color: '#40000000', offsetY: 4 })
    }
    .width('100%').padding({ left: 16, right: 16 }).margin({ top: 12 })
  }

  // ── Route H：Navigation 标题栏（官方生效区域）──
  @Builder
  pocNavTitle() {
    Row({ space: 12 }) {
      Column() {
        Text('‹').fontSize(20).fontColor('#E6E8EB')
      }
      .width(44).height(44).borderRadius(22).justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true
      }))
      Text('H 标题栏材质测试').fontSize(14).fontColor('#E6E8EB')
      Column() {
        Text('☰').fontSize(20).fontColor('#E6E8EB')
      }
      .width(44).height(44).borderRadius(22).justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true
      }))
    }
    .width('100%').padding({ left: 8, right: 8 })
  }

  // ── Route I：Tabs 底部 TabBar（官方生效区域）──
  @Builder
  pocTabItem(glyph: string) {
    Column() {
      Column() {
        Text(glyph).fontSize(20).fontColor('#E6E8EB')
      }
      .width(48).height(48).borderRadius(24).justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true
      }))
    }
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack() {
      this.pocBackground()

      if (this.clean && this.caseKind === 'H') {
        Navigation(new NavPathStack()) {
          Column() {
            Text('标题栏圆钮应获得真材质（官方生效区域）')
              .fontSize(12).fontColor('#E6E8EB')
            Button('返回')
              .fontSize(11).height(28).margin({ top: 12 })
              .onClick(() => {
                this.clean = false;
                this.caseKind = '';
              })
          }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
        }
        .title(this.pocNavTitle, { barStyle: BarStyle.STACK })
        .mode(NavigationMode.Stack)
        .backgroundColor(Color.Transparent)
        .width('100%').height('100%')
      }

      if (this.clean && this.caseKind === 'I') {
        Tabs({ barPosition: BarPosition.End }) {
          TabContent() {
            Column() {
              Text('底部 TabBar 圆钮应获得真材质（官方生效区域）')
                .fontSize(12).fontColor('#E6E8EB')
            Button('返回')
              .fontSize(11).height(28).margin({ top: 12 })
              .onClick(() => {
                this.clean = false;
                this.caseKind = '';
              })
            }
            .width('100%').height('100%').justifyContent(FlexAlign.Center)
          }
          .tabBar(this.pocTabItem('书'))
          TabContent() {
            Column() {
              Text('Tab2').fontSize(12).fontColor('#E6E8EB')
            }
            .width('100%').height('100%')
          }
          .tabBar(this.pocTabItem('☰'))
          TabContent() {
            Column() {
              Text('Tab3').fontSize(12).fontColor('#E6E8EB')
            }
            .width('100%').height('100%')
          }
          .tabBar(this.pocTabItem('我'))
        }
        .barFloatingStyle({
          adaptToHandedness: true,
          systemMaterial: new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN,
            colorInvert: false
          })
        })
        .barOverlap(true)
        .backgroundColor(Color.Transparent)
        .width('100%').height('100%')
      }

      Column() {
        Text('API ' + deviceInfo.sdkApiVersion + ' | ' + this.infoLine)
          .fontSize(11)
          .fontColor('#FFFFFFFF')
          .fontWeight(FontWeight.Bold)
          .margin({ top: 10 })

        Row({ space: 8 }) {
          Button('渐变')
            .fontSize(11)
            .height(28)
            .onClick(() => {
              this.bgKind = 'gradient';
            })
          Button('彩色')
            .fontSize(11)
            .height(28)
            .onClick(() => {
              this.bgKind = 'colorful';
            })
          Button('深色')
            .fontSize(11)
            .height(28)
            .onClick(() => {
              this.bgKind = 'dark';
            })
        }
        .margin({ top: 6 })

        Text('G 伪装供体组件（Slider/Toggle/Select 全区域生效白名单）')
          .fontSize(11)
          .fontColor('#FFFFFFFF')
          .fontWeight(FontWeight.Bold)
          .margin({ top: 14 })
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('G1 裸Slider').fontSize(9).fontColor('#FFFFFFFF')
            Slider({ value: 50, min: 0, max: 100 })
              .width(150)
              .height(36)
              .trackColor(Color.Transparent)
              .selectedColor(Color.Transparent)
              .blockColor(Color.Transparent)
          }
          Column({ space: 4 }) {
            Text('G2 Toggle.Button').fontSize(9).fontColor('#FFFFFFFF')
            Toggle({ type: ToggleType.Button, isOn: false }) {
              Text('G2 壳').fontSize(11)
            }
          }
          Column({ space: 4 }) {
            Text('G3 Select').fontSize(9).fontColor('#FFFFFFFF')
            Select([{ value: 'G3a' }, { value: 'G3b' }])
              .selected(0)
              .width(110)
          }
        }
        .margin({ top: 6 })
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('G5 Chip').fontSize(9).fontColor('#FFFFFFFF')
            Chip({
              label: { text: 'G5 Chip 壳' },
              allowClose: false
            })
          }
          Column({ space: 4 }) {
            Text('G6 透明Slider垫底+图标').fontSize(9).fontColor('#FFFFFFFF')
            Stack({ alignContent: Alignment.Center }) {
              Slider({ value: 50, min: 0, max: 100, style: SliderStyle.InSet })
                .width(110)
                .height(36)
                .trackColor(Color.Transparent)
                .selectedColor(Color.Transparent)
                .blockColor(Color.Transparent)
                .enabled(false)
              Text('玻璃垫底')
                .fontSize(10)
                .fontColor('#FFFFFFFF')
            }
          }
        }
        .margin({ top: 6 })

        Text('Route A：Sheet Material Host（ReaderControlMock 整体承载）')
          .fontSize(11)
          .fontColor('#FFFFFFFF')
          .margin({ top: 10 })

        this.pocFakeMaterialRow()

        Text('HC 锚点（Popup 程序/点击/长按）')
          .fontSize(11)
          .fontColor('#FFFFFFFF')
          .margin({ top: 14 })
        Row() {
          Text('HC')
            .fontSize(16)
            .fontColor('#FFFFFFFF')
            .padding(12)
            .borderRadius(24)
            .backgroundColor('#66000000')
            .bindPopup(this.showPopup, {
              builder: popupBuilderGlobal,
              systemMaterial: thinMaterial(),
              placement: Placement.Top
            } as CustomPopupOptions)
            .gesture(LongPressGesture().onAction((): void => {
              this.showPopup = true;
            }))
          Text('HCmsg')
            .fontSize(13)
            .fontColor('#FFFFFFFF')
            .padding(10)
            .borderRadius(20)
            .backgroundColor('#66000000')
            .margin({ left: 10 })
            .bindPopup(this.showMsgPopup, {
              message: 'HC message popup + systemMaterial',
              systemMaterial: thinMaterial(),
              placement: Placement.Top
            } as PopupOptions)
          Button('HC 点击触发')
            .fontSize(10)
            .height(30)
            .margin({ left: 12 })
            .onClick(() => {
              this.showPopup = true;
            })
        }
        .margin({ top: 6 })

        this.pocV2Panel()
        Button(this.v2Busy ? '生成中…' : 'V2 生成快照 vibrancy 材质')
          .fontSize(11)
          .height(32)
          .margin({ top: 4 })
          .onClick(async (): Promise<void> => {
            await this.buildV2Material();
          })
        Row({ space: 8 }) {
          Button('H Navigation标题栏')
            .fontSize(10)
            .height(30)
            .onClick(() => {
              this.clean = true;
              this.caseKind = 'H';
            })
          Button('I Tabs底栏')
            .fontSize(10)
            .height(30)
            .onClick(() => {
              this.clean = true;
              this.caseKind = 'I';
            })
        }
        .margin({ top: 6 })


        Text('HD 锚点（ContextMenu 长按）')
          .fontSize(11)
          .fontColor('#FFFFFFFF')
          .margin({ top: 14 })
        Text('长按我：模拟划词菜单')
          .fontSize(14)
          .fontColor('#FFFFFFFF')
          .padding(12)
          .borderRadius(10)
          .backgroundColor('#66000000')
          .bindContextMenu(this.menuBuilder, ResponseType.LongPress, {
            systemMaterial: thinMaterial()
          } as ContextMenuOptions)
          .margin({ top: 6 })

        Column({ space: 6 }) {
          Button('HA Sheet 全屏承载 Mock')
            .fontSize(10)
            .height(30)
            .onClick(() => {
              this.showMockSheet = true;
            })
          Button('HB AlertDialog(文本上限)')
            .fontSize(10)
            .height(30)
            .onClick(() => {
              this.openCase('HB');
            })
        }
        .margin({ top: 12 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: 20 })

      // Route A：Sheet Material Host
      Column() {
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .bindSheet($$this.showMockSheet, this.pocReaderControlMock(), {
        height: 640,
        mode: SheetMode.OVERLAY,
        showClose: true,
        systemMaterial: thinMaterial()
      })
    }
    .width('100%')
    .height('100%')
  }
}
