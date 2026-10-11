import type { Margins } from 'ohrengine-common';
import { IconAssets } from '../common/IconAssets.ets';
import { ReaderTheme } from '../common/ReaderTheme.ets';

/**
 * 阅读状态信息（保持原有布局：左下时间 + 电量图标，右下页码）。
 * 位于阅读内容区域下边界以下 4px，正文区域之外、不遮挡内容。
 * 电量使用填充型图标，不做档位变色、不显示百分比文字。
 */
@Component
export struct ReaderStatusBar {
  @Prop timeText: string = '--:--';
  @Prop batteryCharging: boolean = false;
  @Prop batterySoc: number = -1;
  @Prop pageRightText: string = '';
  margins: Margins = { left: 10, right: 10, top: 50, bottom: 36 } as Margins;
  avoidAreaBottom: number = 0;
  contentWidth: number = 344;
  canvasH: number = 800;

  build() {
    Stack() {
      // 左下：时间 + 电量图标（填充型，默认色）
      Row({ space: 8 }) {
        Text(this.timeText)
          .fontSize(13).fontColor(ReaderTheme.textTertiary).fontWeight(FontWeight.Normal)
        Image(IconAssets.batteryFilled())
          .width(19).height(19)
          .objectFit(ImageFit.Contain)
          .fillColor(ReaderTheme.textTertiary)
      }
      .position({
        left: this.margins.left,
        bottom: this.avoidAreaBottom + this.margins.bottom - 4
      })
      .zIndex(98)

      // 右下：页码
      Text(this.pageRightText)
        .fontSize(13).fontColor(ReaderTheme.textTertiary)
        .position({
          right: this.margins.right,
          bottom: this.avoidAreaBottom + this.margins.bottom - 4
        })
        .zIndex(98)
    }
    .width('100%').height('100%')
    // 不拦截触摸：状态显示只读
    .hitTestBehavior(HitTestMode.None)
  }
}