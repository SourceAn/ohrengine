import type { FontTheme } from 'ohrengine-feature';
import type { Margins } from 'ohrengine-common';
import { MaterialConfig } from '../common/MaterialConfig.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 字体面板（锚定菜单栏行1 字体胶囊上方弹出，横向滚动卡片）。
 */
@Component
export struct FontPanel {
  @StorageProp('darkMode') darkMode: boolean = false;
  fontThemes: FontTheme[] = [];
  @Prop currentFontThemeId: string = '';
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaBottom: number = 0;
  onSelectTheme: (id: string) => void = () => {};

  build() {
    Column() {
      Scroll() {
        Row({ space: 10 }) {
          ForEach(this.fontThemes, (ft: FontTheme) => {
            Column() {
              Text(ft.name).fontSize(13).fontColor(ReaderTheme.textPrimary)
              Text(ft.fontFamily.split(',')[0]).fontSize(10).fontColor(ReaderTheme.textTertiary)
                .maxLines(1).margin({ top: 4 })
            }
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .backgroundColor(this.currentFontThemeId === ft.id
              ? (this.darkMode ? '#1F3A5C' : '#E8F1FB')
              : (this.darkMode ? '#2C2C2E' : '#F7F7F7'))
            .borderRadius(12)
            .border({
              width: this.currentFontThemeId === ft.id ? 2 : 1,
              color: this.currentFontThemeId === ft.id ? ReaderTheme.accent : ReaderTheme.divider
            })
            .onClick(() => {
              this.onSelectTheme(ft.id);
            })
          })
        }
        .padding(4)
      }
      .height(56).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
    }
    .padding(10)
    .backgroundColor(MaterialConfig.cardBg())
    .backgroundBlurStyle(MaterialConfig.cardBlur())
    .systemMaterial(MaterialConfig.cardMaterial())
    .borderRadius(16)
    // 菜单栏总高 160（36*3 + 12*2 + 14*2），面板下缘贴菜单栏上缘 + 8 间距
    .position({ left: this.margins.left + 16, bottom: this.avoidAreaBottom + this.margins.bottom + 168 })
    .transition(TransitionEffect.translate({ y: 20 }))
    .zIndex(105)
  }
}
