import { OhEngine, FontFallbackChain, TextSegment, LoadedFontInfo, ReadingMetrics, FauxBoldItalicRenderer, RubyRenderer, LineRubySegment, RubyRenderOptions, MathMLRenderer, MathMlRenderOptions, SvgRenderer, TableRenderer, GridResult, AnnotationRenderer, RemoteResourceLoader, RequestCanceller } from 'ohrengine-ui-render';
import { Theme } from 'ohrengine-feature';
import { SelectionRenderer } from 'ohrengine-feature';
import type { PageSlot, Margins, LineBox } from 'ohrengine-common';
import type { Annotation } from 'ohrengine-common';
import type { SelectionRange } from 'ohrengine-feature';
import { image } from '@kit.ImageKit';

export interface ReaderViewport {
  canvasW: number;
  canvasH: number;
  contentWidth: number;
  contentHeight: number;
  margins: Margins;
  avoidAreaTopVp: number;
}

export interface PageRendererDeps {
  engine: OhEngine;
  canvasCtx: CanvasRenderingContext2D;
  getViewport: () => ReaderViewport;
  getAnnotations: () => Annotation[];
  getSelection: () => SelectionRange | null;
  /** 内容变更回调（异步图片解码完成等；触发页面重绘） */
  onContentChanged?: () => void;
  /**
   * 翻页会话冻结查询（FlipSession）：翻页动画期间返回 true 时，
   * 异步图片解码完成不更新纹理缓存、不触发重绘——动画期间内容/纹理
   * 保持一致（避免 BACK 倒放等长动画中画面闪烁）。
   */
  isFlipActive?: () => boolean;
  /** 下拉添加书签：当前下拉位移（vp，>0 时内容整体下移并绘制书签填充） */
  getPullDistance?: () => number;
  /** 下拉添加书签：当前填充进度 0~1（0=空白 1=书签填充满） */
  getPullProgress?: () => number;
}

/**
 * Canvas 页面绘制器：负责把当前页绘制到画布。
 * 坐标系：Canvas 铺满全窗口，内容区整体平移至 (margins.left, margins.top + avoidAreaTopVp)。
 */
export class PageRenderer {
  /** 屏幕密度（vp→px；静态帧直绘缩放用，Index 注入） */
  private screenDensity: number = 3.0;
  private engine: OhEngine;
  private canvasCtx: CanvasRenderingContext2D;
  private getViewport: () => ReaderViewport;
  private getAnnotations: () => Annotation[];
  private getSelection: () => SelectionRange | null;
  private bookBasePath: string = '';
  private remoteImageCache: Map<string, image.PixelMap> = new Map();
  private localImageCache: Map<string, image.PixelMap> = new Map();
  private resourceLoader: RemoteResourceLoader | null = null;
  private tableRenderer: TableRenderer = new TableRenderer();
  // 已销毁标记（ENG-003）：页面销毁后不再提交绘制指令，异步图片解码回调也被拦截
  private disposed: boolean = false;
  // 远程请求取消令牌（ENG-013）：页面销毁时中止进行中的网络请求
  private requestCanceller: RequestCanceller = new RequestCanceller();
  /** 内容变更回调（异步图片解码完成 → 触发页面重绘） */
  private onContentChanged: (() => void) | null = null;
  /** 翻页会话冻结查询（FlipSession）：动画期间为 true → 不更新纹理/不重绘 */
  private isFlipActive: (() => boolean) | null = null;
  /** 下拉添加书签：下拉位移读取器（动画回弹期间逐帧驱动画布重绘） */
  private getPullDistance: (() => number) | null = null;
  /** 下拉添加书签：填充进度读取器 */
  private getPullProgress: (() => number) | null = null;
  /** 纸背透印(BackBleed)文字 alpha：真实纸张背面浅淡印记（低 alpha 油墨） */
  private readonly BACK_BLEED_TEXT_ALPHA: number = 0.15;
  /** 纸背透印(BackBleed)图片 alpha：比文字更淡（纸张透射图片最弱） */
  private readonly BACK_BLEED_IMAGE_ALPHA: number = 0.10;

  constructor(deps: PageRendererDeps) {
    this.engine = deps.engine;
    this.canvasCtx = deps.canvasCtx;
    this.getViewport = deps.getViewport;
    this.getAnnotations = deps.getAnnotations;
    this.getSelection = deps.getSelection;
    this.onContentChanged = deps.onContentChanged ?? null;
    this.isFlipActive = deps.isFlipActive ?? null;
    this.getPullDistance = deps.getPullDistance ?? null;
    this.getPullProgress = deps.getPullProgress ?? null;
  }

  /**
   * 释放：置位销毁标记，阻止页面销毁后继续绘制。
   * 由页面壳（Index.ets）在 aboutToDisappear 中转发调用（ENG-003）。
   */
  dispose(): void {
    this.disposed = true;
    // 中止进行中的远程请求（ENG-013）
    this.requestCanceller.abort();
    this.requestCanceller = new RequestCanceller();
    this.remoteImageCache.clear();
    this.localImageCache.clear();
  }

  setBookBasePath(path: string): void {
    this.bookBasePath = path;
    this.tableRenderer.bookBasePath = path;
  }

  /** 读取书籍资源基路径（封面相对路径解析用） */
  getBookBasePath(): string {
    return this.bookBasePath;
  }

  /** 注入屏幕密度（静态帧直绘缩放；Index 在 initEngine 后调用） */
  setScreenDensity(density: number): void {
    if (density > 0) {
      this.screenDensity = density;
    }
  }

  /**
   * Phase 10 诊断：目标页图片资产解码状态（decoded/total，含 list-style-image）。
   * 供翻页动画入口日志验证 N+1/N-1 资产就绪对称性（S3 假说）。
   */
  describePageImages(page: PageSlot): string {
    let total: number = 0;
    let decoded: number = 0;
    for (let i: number = 0; i < page.lines.length; i++) {
      const lsrc: string | undefined = page.lines[i].imageSrc;
      if (lsrc !== undefined && lsrc.length > 0) {
        total++;
        if (lsrc.startsWith('http://') || lsrc.startsWith('https://')) {
          if (this.remoteImageCache.has(lsrc)) {
            decoded++;
          }
        } else {
          const full: string = this.resolveImagePath(this.bookBasePath, lsrc);
          if (this.localImageCache.has(full)) {
            decoded++;
          }
        }
      }
      const msrc: string | undefined = page.lines[i].markerImageSrc;
      if (msrc !== undefined && msrc.length > 0) {
        total++;
        if (msrc.startsWith('http://') || msrc.startsWith('https://')) {
          if (this.remoteImageCache.has(msrc)) {
            decoded++;
          }
        } else {
          const mfull: string = this.resolveImagePath(this.bookBasePath, msrc);
          if (this.localImageCache.has(mfull)) {
            decoded++;
          }
        }
      }
    }
    return 'imgDec=' + String(decoded) + '/' + String(total);
  }

  renderPage(): void {
    if (this.disposed) {
      return;
    }
    const vp = this.getViewport();
    const ctx = this.canvasCtx;
    this.drawCurrentPageToContext(ctx, vp.canvasW, vp.canvasH);
  }

  /**
   * 把当前页内容绘制到指定 Canvas 上下文。
   * 坐标系：全屏画布（vp），内容区整体平移至 (margins.left, margins.top + avoidAreaTopVp)。
   * 与 renderPage 同管线（正文排版绘制质量逻辑不变，仅目标上下文可注入）。
   * 单位说明：显示 Canvas 为 vp 单位，本方法
   * 全程以 vp 坐标直接绘制，不再做 density 缩放；canvasW/canvasH 为引擎传入的 px 尺寸，
   * 保留签名以维持调用契约，但不再用于填充——背景按 vp 视口尺寸填充。
   *
   * @param ctx 目标 Canvas 上下文（显示 Canvas）
   * @param canvasW 画布宽（px，引擎传入；保留签名，不再用于填充）
   * @param canvasH 画布高（px，引擎传入；保留签名，不再用于填充）
   */
  drawCurrentPageToContext(ctx: CanvasRenderingContext2D, canvasW: number, canvasH: number): void {
    if (this.disposed) {
      return;
    }
    const vp = this.getViewport();
    const page: PageSlot | undefined = this.engine.getCurrentPage();
    const theme: Theme = this.engine.getThemeManager().currentTheme;
    const pullDy: number = this.getPullDistance !== null ? this.getPullDistance() : 0;
    const pullProgress: number = this.getPullProgress !== null ? this.getPullProgress() : 0;
    ctx.save();
    ctx.fillStyle = theme.backgroundColor;
    // 背景按 vp 视口尺寸铺满（显示 Canvas 为 vp 单位，全屏即 vp.canvasW × vp.canvasH）
    ctx.fillRect(0, 0, vp.canvasW, vp.canvasH);
    if (!page) {
      ctx.restore();
      return;
    }
    // ── 下拉添加书签：揭示顶部空白区（书签填充动画）+ 内容整体下移 ──
    if (pullDy > 0.5) {
      this.drawBookmarkPullZone(ctx, vp, pullDy, pullProgress);
      ctx.translate(0, pullDy);
    }
    ctx.translate(vp.margins.left, vp.margins.top + vp.avoidAreaTopVp);
    // Phase 24 (Issue C)：未加载页最小视觉表达——stub 页不再渲染为纯空白。
    // STUB+LOADING → 「正在加载…」；FAILED（章节内容不可得）→ 「内容加载失败」。
    // 真实内容页的绘制路径完全不变。
    if (page.state === 'stub') {
      const failed: boolean = this.engine.isChunkLayoutFailed(page.chunkIndex);
      ctx.save();
      ctx.fillStyle = theme.textColor;
      ctx.globalAlpha = 0.35;
      ctx.font = '16px sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(failed ? '内容加载失败' : '正在加载…',
        vp.contentWidth / 2, vp.contentHeight / 2);
      ctx.restore();
    }
    // 显示 Canvas 为 vp 单位，字体用 vp（与旧 onscreen renderPage 的 vp 语义一致）
    this.drawPageContent(ctx, page, 'vp');
    ctx.restore();
  }

  /**
   * 把屏幕指定区域（vp，全屏坐标系）内的当前页内容绘制到目标上下文（局部坐标 0,0 起）。
   * 供底部液态玻璃面板的「背景镜像」使用：玻璃背后内容需由 bgContent 自绘，
   * 该镜像与显示 Canvas 同管线绘制，位置/字形与真实屏幕一致，玻璃边缘与四角无缝。
   *
   * @param ctx 目标 Canvas 上下文（面板尺寸）
   * @param x0 屏幕区域左上角 x（vp）
   * @param y0 屏幕区域左上角 y（vp）
   * @param w 区域宽（vp）
   * @param h 区域高（vp）
   */
  drawScreenRegion(ctx: CanvasRenderingContext2D, x0: number, y0: number, w: number, h: number): void {
    if (this.disposed || w <= 0 || h <= 0) {
      return;
    }
    const vp = this.getViewport();
    const page: PageSlot | undefined = this.engine.getCurrentPage();
    const theme: Theme = this.engine.getThemeManager().currentTheme;
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, w, h);
    ctx.clip();
    ctx.translate(-x0, -y0);
    ctx.fillStyle = theme.backgroundColor;
    ctx.fillRect(0, 0, vp.canvasW, vp.canvasH);
    if (page !== undefined) {
      const originY: number = vp.margins.top + vp.avoidAreaTopVp;
      ctx.translate(vp.margins.left, originY);
      // 可见行裁剪：只绘制区域内的行，避免整页无谓绘制
      this.drawPageContent(ctx, page, 'vp', 1, y0 - originY, y0 + h - originY);
    }
    ctx.restore();
  }

  /**
   * 下拉添加书签揭示区：
   * - 顶部空白区微染 + 内容上边界分隔影；
   * - 内容区右上角显示 bookmark-fill 书签符号，红色随进度从无到有填充。
   * `dy` 为内容已下移的距离（空白区高度），`progress` 0~1 对应红色填充渐显。
   */
  private drawBookmarkPullZone(ctx: CanvasRenderingContext2D, vp: ReaderViewport, dy: number, progress: number): void {
    // 揭示区顶部微染：进度越高越明显
    ctx.fillStyle = 'rgba(255,59,48,' + (0.05 * Math.min(1, progress)).toFixed(3) + ')';
    ctx.fillRect(0, 0, vp.canvasW, dy);
    // 内容上边界分隔线
    ctx.fillStyle = 'rgba(34,39,46,0.12)';
    ctx.fillRect(0, dy, vp.canvasW, 2);
    // 分隔线下方阴影渐变（模拟内容被拉起后的投影）
    const shadowGrad: CanvasGradient = ctx.createLinearGradient(0, dy, 0, dy + 12);
    shadowGrad.addColorStop(0, 'rgba(0,0,0,0.12)');
    shadowGrad.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = shadowGrad;
    ctx.fillRect(0, dy, vp.canvasW, 12);
    // ── 右上角 bookmark-fill 书签：红色从无到有 ──
    const iconSize: number = 34;
    const px: number = vp.canvasW - vp.margins.right - iconSize - 10;
    const py: number = vp.avoidAreaTopVp + 10;
    ctx.save();
    ctx.translate(px, py);
    ctx.scale(iconSize / 24, iconSize / 24);
    // 幽灵轮廓（目标形态提示）
    ctx.beginPath();
    PageRenderer.traceBookmarkGlyph(ctx);
    ctx.strokeStyle = 'rgba(255,59,48,0.40)';
    ctx.lineWidth = 1.6;
    ctx.stroke();
    // 红色实体填充：progress 0→1 从无到有
    if (progress > 0.01) {
      ctx.beginPath();
      PageRenderer.traceBookmarkGlyph(ctx);
      ctx.globalAlpha = Math.min(1, progress);
      ctx.fillStyle = '#FF3B30';
      ctx.fill();
      if (progress >= 1) {
        // 达到触发距离：微红光晕确认
        ctx.shadowBlur = 10;
        ctx.shadowColor = 'rgba(255,59,48,0.60)';
        ctx.fill();
        ctx.shadowBlur = 0;
        ctx.shadowColor = '#00000000';
      }
    }
    ctx.restore();
  }

  /** 绘制 bookmark-fill 书签字形路径（24×24 视口坐标系内，与 ic_public_bookmark 一致） */
  private static traceBookmarkGlyph(ctx: CanvasRenderingContext2D): void {
    ctx.moveTo(6.5, 3);
    ctx.bezierCurveTo(6.5, 2.17157288, 7.17157288, 1.5, 8, 1.5);
    ctx.lineTo(16, 1.5);
    ctx.bezierCurveTo(16.8284271, 1.5, 17.5, 2.17157288, 17.5, 3);
    ctx.lineTo(17.5, 20.5);
    ctx.bezierCurveTo(17.5, 20.7761424, 17.2761424, 21, 17, 21);
    ctx.bezierCurveTo(16.8639047, 21, 16.7311235, 20.944087, 16.6314586, 20.8423034);
    ctx.lineTo(12, 16.2108108);
    ctx.lineTo(7.36854143, 20.8423034);
    ctx.bezierCurveTo(7.26887653, 20.944087, 7.1360953, 21, 7, 21);
    ctx.bezierCurveTo(6.72385763, 21, 6.5, 20.7761424, 6.5, 20.5);
    ctx.closePath();
  }

  /**
   * 绘制指定页面的内容。
   * 坐标系：已 translate 到内容区原点（调用方负责）。
   *
   * @param ctx Canvas 上下文
   * @param page 要绘制的页面
   * @param fontUnit 字体单位（'vp'=ArkUI Canvas 屏上渲染；'px'=离屏内容生产，
   *                 离屏上下文不识别 vp 单位，需显式 px）
   * @param densityScale 字体密度缩放（离屏位图渲染用：离屏像素 = vp × density，
   *                     调用方负责 scale(density) 变换，此处仅缩放字体字号与
   *                     letterSpacing，默认 1 表示屏上渲染）
   */
  drawPageContent(ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D, page: PageSlot,
    fontUnit: string = 'vp', densityScale: number = 1,
    visibleY0: number = -1, visibleY1: number = 1e9,
    skipComplex: boolean = false, complexOnly: boolean = false,
    renderMode: string = 'normal'): void {
    const vp = this.getViewport();
    const theme: Theme = this.engine.getThemeManager().currentTheme;
    const fontSize: number = this.engine.getFontSizeController().userFontSize;
    ctx.save();
    // ⚠ 显式强制复位 globalAlpha：鸿蒙 Canvas 的 globalAlpha getter 恒返回
    //    undefined（无法读回校验），save/restore 是否还原该属性不可靠。
    //    必须在每次绘制入口强制 1.0，杜绝上一帧 backbleed 透印残留污染
    //    本帧 normal 层（正面图片/文字变 0.10）。
    ctx.globalAlpha = 1.0;
    ctx.letterSpacing = ((this.engine.getLayoutProfile().letterSpacing || 0) * densityScale) + 'px';
    ctx.fillStyle = theme.textColor;
    const fallback: FontFallbackChain = this.engine.getFontFallbackChain();
    let y = 0;
    for (const line of page.lines) {
      // ── 行进距与分页度量严格一致：优先用排版产出的实测 line.height
      // （TextBreaker：lineHeight + lineSpacing；含 CSS 行高/标题字号差异），
      // 仅在异常缺失时回退估算值。若绘制端自行按当前字号重算行进距，
      // 与分页打包用的度量不一致时（如重排前的旧页面），行数超出
      // 分页假设，内容会溢出内容区下边界。
      const fallbackAdvance: number =
        fontSize * ReadingMetrics.LINE_HEIGHT_RATIO + this.engine.getLineSpacing();
      const lineAdvance: number = line.height > 0 ? line.height : fallbackAdvance;
      // ── 可见行裁剪（翻页动画优化）：Y 已越过可见区下界 → 剩余行全部不可见 ──
      if (y > visibleY1) {
        break;
      }
      // Record rendered Y for text selection hit-testing
      line.renderedY = y;

      // Command 2: overflow:hidden Canvas 裁剪（在渲染前应用，在 continue/渲染后恢复）
      const needsClip: boolean = line.containerOverflow === 'hidden';
      if (needsClip) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(line.containerX!, line.containerY!, line.containerWidth!, line.containerHeight!);
        ctx.clip();
      }

      // ── 复杂行过滤（纸背卷曲绘制用）：skipComplex 跳过复杂行（弯曲段逐条画），
      //    complexOnly 只画复杂行（按行中心单次变换绘制）──
      if (skipComplex === true || complexOnly === true) {
        const isComplexLine: boolean = line.isFloat === true ||
          (line.imageSrc !== undefined && line.imageSrc.length > 0) ||
          line.gridResult !== undefined || line.mathMlExpr !== undefined ||
          line.svgDoc !== undefined;
        if ((skipComplex === true && isComplexLine) || (complexOnly === true && !isComplexLine)) {
          // 推进 y 与各分支一致（普通行按行高；复杂行各自推进；float 绝对定位不推进）
          if (!isComplexLine) {
            const skipH: number = lineAdvance;
            y += skipH;
          } else if (line.imageSrc !== undefined && line.imageSrc.length > 0) {
            y += vp.contentHeight - y;
          } else if (line.gridResult !== undefined) {
            const gRes: GridResult = line.gridResult as GridResult;
            y += gRes.totalHeight;
          } else if (line.mathMlExpr !== undefined || line.svgDoc !== undefined) {
            y += line.height;
          }
          if (needsClip) ctx.restore();
          continue;
        }
      }

      // ── 可见行裁剪：行整体在可见区上方 → 跳过（复杂行保留绘制，避免布局语义偏移）──
      const isComplex: boolean = line.isFloat === true ||
        (line.imageSrc !== undefined && line.imageSrc.length > 0) ||
        line.gridResult !== undefined || line.mathMlExpr !== undefined ||
        line.svgDoc !== undefined;
      if (!isComplex) {
        const blockH: number = lineAdvance;
        if (y + blockH < visibleY0) {
          y += blockH;
          if (needsClip) ctx.restore();
          continue;
        }
      }

      // ── 浮动元素：绘制定位盒 + 内部文本 ──
      // 盒模型：margin 区域透明 → border-box 背景/边框 → content 文本
      if (line.isFloat === true) {
        const floatMarginL: number = line.marginLeft ?? 0;
        const floatMarginR: number = line.marginRight ?? 0;
        const floatMarginT: number = line.marginTop ?? 0;
        const floatMarginB: number = line.marginBottom ?? 0;
        // border-box = margin-box 减去 margin
        const borderX: number = line.x + floatMarginL;
        const borderY: number = line.y + floatMarginT;
        const borderW: number = Math.max(0, line.width - floatMarginL - floatMarginR);
        const borderH: number = Math.max(0, line.height - floatMarginT - floatMarginB);
        // margin 区域透明（canvas 默认即透明，不绘制即为透明）
        // 绘制 border-box 背景
        ctx.fillStyle = '#f0f0f0';
        ctx.fillRect(borderX, borderY, borderW, borderH);
        ctx.strokeStyle = '#cccccc';
        ctx.lineWidth = 1;
        ctx.strokeRect(borderX, borderY, borderW, borderH);
        // 文本绘制在 content 区域（border-box 内缩 8vp ≈ padding）
        const contentPad: number = 8;
        ctx.fillStyle = theme.textColor;
        ctx.font = (fontSize * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
        // 纸背透印(BackBleed)：文字低 alpha
        if (renderMode === 'backbleed') ctx.globalAlpha = this.BACK_BLEED_TEXT_ALPHA;
        ctx.fillText(line.text, borderX + contentPad, borderY + contentPad + fontSize);
        if (renderMode === 'backbleed') ctx.globalAlpha = 1.0;
        if (needsClip) ctx.restore();
        continue;
      }

      if (line.imageSrc && line.imageSrc.length > 0) {
        try {
          const src: string = line.imageSrc;
          // 纸背透印(BackBleed)：图片更低 alpha（纸张透射图片最弱）
          if (renderMode === 'backbleed') ctx.globalAlpha = this.BACK_BLEED_IMAGE_ALPHA;
          if (src.startsWith('http://') || src.startsWith('https://')) {
            // 远程图片：尝试从缓存中获取 PixelMap
            const cached: image.PixelMap | undefined = this.remoteImageCache.get(src);
            if (cached !== undefined) {
              this.drawImageScaled(ctx, cached, line.x, y, vp.contentWidth, vp.contentHeight - y);
            } else {
              // 缓存未命中：不画占位（避免 "[加载远程图片...]" 闪现），异步加载
              this.loadRemoteImage(src);
            }
          } else {
            // 本地图片：从 localImageCache 中获取 PixelMap（异步解码，仿 remoteImageCache 模式）
            const fullPath: string = this.resolveImagePath(this.bookBasePath, src);
            const cached: image.PixelMap | undefined = this.localImageCache.get(fullPath);
            if (cached !== undefined) {
              this.drawImageScaled(ctx, cached, line.x, y, vp.contentWidth, vp.contentHeight - y);
            } else {
              // 缓存未命中：不画任何占位（避免 "[加载中...]" 闪现），
              // 异步解码完成后 renderPage 重绘出图。
              this.preloadLocalImage(src);
            }
          }
        } catch (_e) { }
        // 图片透印 alpha 复位
        if (renderMode === 'backbleed') ctx.globalAlpha = 1.0;
        y += vp.contentHeight - y;
        if (needsClip) ctx.restore();
        continue;
      }

      // 表格：绘制网格 + 单元格内容（支持跨页分点）
      if (line.gridResult !== undefined) {
        ctx.fillStyle = theme.textColor;
        ctx.font = (14 * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
        const gridRes: GridResult = line.gridResult as GridResult;
        // 纸背透印：表格按文字 alpha
        if (renderMode === 'backbleed') ctx.globalAlpha = this.BACK_BLEED_TEXT_ALPHA;
        this.tableRenderer.render(ctx as CanvasRenderingContext2D, gridRes, line.x, y, fontUnit, densityScale);
        if (renderMode === 'backbleed') ctx.globalAlpha = 1.0;
        y += gridRes.totalHeight;
        if (needsClip) ctx.restore();
        continue;
      }

      // MathML 公式：使用 MathMLRenderer 绘制
      if (line.mathMlExpr !== undefined) {
        const opts: MathMlRenderOptions = {
          fontSize: fontSize * densityScale,
          fontFamily: 'HarmonyOS Sans',
          color: theme.textColor,
          lineWidth: Math.max(densityScale, (fontSize * densityScale) / 24),
          fractionLineExtra: (fontSize * densityScale) * 0.15,
          radicalExtra: (fontSize * densityScale) * 0.05,
          scriptScale: 0.65,
          scriptOffset: 0.4,
          unit: fontUnit
        };
        // 纸背透印：公式按图片 alpha（图形类）
        if (renderMode === 'backbleed') ctx.globalAlpha = this.BACK_BLEED_IMAGE_ALPHA;
        MathMLRenderer.draw(ctx as CanvasRenderingContext2D, line.mathMlExpr, line.x, y + line.ascent, opts);
        if (renderMode === 'backbleed') ctx.globalAlpha = 1.0;
        y += line.height;
        if (needsClip) ctx.restore();
        continue;
      }

      // SVG 矢量图形：使用 SvgRenderer 绘制
      if (line.svgDoc !== undefined) {
        // 纸背透印：SVG 按图片 alpha（图形类）
        if (renderMode === 'backbleed') ctx.globalAlpha = this.BACK_BLEED_IMAGE_ALPHA;
        SvgRenderer.draw(ctx as CanvasRenderingContext2D, line.svgDoc, line.x, y, line.width, line.height, densityScale);
        if (renderMode === 'backbleed') ctx.globalAlpha = 1.0;
        y += line.height;
        if (needsClip) ctx.restore();
        continue;
      }

      const lineH: number = fontSize * ReadingMetrics.LINE_HEIGHT_RATIO;
      const lineOpacity: number = line.effectiveOpacity ?? 1.0;

      // ── Opacity: skip fully transparent lines ──
      if (lineOpacity <= 0) {
        y += lineAdvance;
        if (needsClip) ctx.restore();
        continue;
      }

      // ── 文字 alpha = 纸背透印(BackBleed) × 行透明度：normal=1.0，backbleed=0.15 ──
      const textAlpha: number = (renderMode === 'backbleed' ? this.BACK_BLEED_TEXT_ALPHA : 1.0) * lineOpacity;
      if (textAlpha < 1) {
        ctx.globalAlpha = textAlpha;
      }

      const baselineY: number = y + lineH * ReadingMetrics.BASELINE_OFFSET;

      // sup/sub 上下标：字号缩放 + 基线偏移
      let renderFontSize: number = fontSize;
      let baselineOffset: number = 0;
      if (line.isSuperscript) {
        renderFontSize = fontSize * 0.65;
        baselineOffset = -fontSize * 0.33;
      } else if (line.isSubscript) {
        renderFontSize = fontSize * 0.65;
        baselineOffset = fontSize * 0.20;
      }

      const renderBaselineY: number = baselineY + baselineOffset;

      if (line.charPositions && line.charPositions.length > 0) {
        // 按字体分段整段绘制（业界标准：整段 shaping + Canvas measureText 推进，
        // 测量与渲染同引擎，字符天然不重叠）。charPositions 仅用于文本选择
        // 命中测试，不参与绘制定位。
        const fontLoader = this.engine.getFontLoader();
        const loadedFontEntries: LoadedFontInfo[] = fallback.getFamilies()
          .map((name: string): LoadedFontInfo => ({ familyName: name }));
        const segments: TextSegment[] = fallback.resolveTextSegments(line.text, line.fontFamilyList, loadedFontEntries);
        let segX: number = line.x;
        for (const seg of segments) {
          const baseFont: string = seg.fontFamily || 'HarmonyOS Sans';
          const fontFamily: string = fontLoader.getFontForChar(seg.text[0], baseFont) ?? 'HarmonyOS Sans';
          ctx.font = (renderFontSize * densityScale) + fontUnit + ' ' + fontFamily + ', sans-serif';
          const fontWeight: number = line.fontWeight ?? 400;
          const fontStyle: string = line.fontStyle ?? 'normal';
          const fontSynthesis: string = line.fontSynthesis ?? 'weight style';
          const needsFauxBold: boolean = fontWeight > 400 &&
            fontSynthesis.indexOf('weight') >= 0 &&
            fontLoader.needsFauxBold(fontFamily, fontWeight, seg.text[0]);
          const needsFauxItalic: boolean = fontStyle !== 'normal' &&
            fontSynthesis.indexOf('style') >= 0 &&
            !fontLoader.hasGlyph(fontFamily, fontWeight, fontStyle);
          if (needsFauxBold && needsFauxItalic) {
            ctx.save();
            ctx.fillStyle = theme.textColor;
            ctx.strokeStyle = theme.textColor;
            const skew: number = 0.25;
            ctx.transform(1, 0, skew, 1, -renderFontSize * skew * 0.3, 0);
            const offset: number = FauxBoldItalicRenderer.getBoldOffset(renderFontSize, seg.text);
            ctx.lineWidth = offset * 2.5;
            ctx.lineJoin = 'round';
            ctx.strokeText(seg.text, segX, renderBaselineY);
            ctx.fillText(seg.text, segX, renderBaselineY);
            ctx.restore();
          } else if (needsFauxBold) {
            FauxBoldItalicRenderer.renderBold(ctx as CanvasRenderingContext2D, seg.text, segX, renderBaselineY,
              renderFontSize, theme.textColor);
          } else if (needsFauxItalic) {
            FauxBoldItalicRenderer.renderItalic(ctx as CanvasRenderingContext2D, seg.text, segX, renderBaselineY,
              renderFontSize, theme.textColor);
          } else {
            ctx.fillText(seg.text, segX, renderBaselineY);
          }
          const metrics: TextMetrics = ctx.measureText(seg.text);
          segX += metrics.width;
        }
      } else {
        // Left-aligned — render segment by segment with accumulated x offset
        const fontLoader = this.engine.getFontLoader();
        const loadedFontEntries: LoadedFontInfo[] = fallback.getFamilies()
          .map((name: string): LoadedFontInfo => ({ familyName: name }));
        const segments: TextSegment[] = fallback.resolveTextSegments(line.text, line.fontFamilyList, loadedFontEntries);
        let segX: number = line.x;
        for (const seg of segments) {
          const baseFont: string = seg.fontFamily || 'HarmonyOS Sans';
          // 通过 unicode-range 验证段首字符，无匹配则回退系统字体
          const fontFamily: string = fontLoader.getFontForChar(seg.text[0], baseFont) ?? 'HarmonyOS Sans';
          ctx.font = (renderFontSize * densityScale) + fontUnit + ' ' + fontFamily + ', sans-serif';
          const fontWeight: number = line.fontWeight ?? 400;
          const fontStyle: string = line.fontStyle ?? 'normal';
          const fontSynthesis: string = line.fontSynthesis ?? 'weight style';
          const needsFauxBold: boolean = fontWeight > 400 &&
            fontSynthesis.indexOf('weight') >= 0 &&
            fontLoader.needsFauxBold(fontFamily, fontWeight, seg.text[0]);
          const needsFauxItalic: boolean = fontStyle !== 'normal' &&
            fontSynthesis.indexOf('style') >= 0 &&
            !fontLoader.hasGlyph(fontFamily, fontWeight, fontStyle);
          if (needsFauxBold && needsFauxItalic) {
            // Both: apply faux italic then faux bold within a single save/restore
            ctx.save();
            ctx.fillStyle = theme.textColor;
            ctx.strokeStyle = theme.textColor;
            const skew: number = 0.25;
            ctx.transform(1, 0, skew, 1, -renderFontSize * skew * 0.3, 0);
            const offset: number = FauxBoldItalicRenderer.getBoldOffset(renderFontSize, seg.text);
            ctx.lineWidth = offset * 2.5;
            ctx.lineJoin = 'round';
            ctx.strokeText(seg.text, segX, renderBaselineY);
            ctx.fillText(seg.text, segX, renderBaselineY);
            ctx.restore();
          } else if (needsFauxBold) {
            FauxBoldItalicRenderer.renderBold(ctx as CanvasRenderingContext2D, seg.text, segX, renderBaselineY,
              renderFontSize, theme.textColor);
          } else if (needsFauxItalic) {
            FauxBoldItalicRenderer.renderItalic(ctx as CanvasRenderingContext2D, seg.text, segX, renderBaselineY,
              renderFontSize, theme.textColor);
          } else {
            ctx.fillText(seg.text, segX, renderBaselineY);
          }
          const metrics: TextMetrics = ctx.measureText(seg.text);
          segX += metrics.width;
        }
      }

      // 绘制列表标记（如有）
      if (line.listMarker !== undefined && line.listMarker !== '') {
        const markerFontSize: number = line.listMarkerFontSize ?? renderFontSize;
        const markerColor: string = line.listMarkerColor ?? '#888888';
        ctx.fillStyle = markerColor;
        ctx.font = (markerFontSize * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
        ctx.fillText(line.listMarker, line.listMarkerX ?? 0, renderBaselineY);
        ctx.fillStyle = theme.textColor;
      }

      // 绘制列表项 image marker（list-style-image）
      if (line.markerImageSrc !== undefined && line.markerImageSrc.length > 0) {
        const markerSize: number = line.listMarkerFontSize ?? renderFontSize;
        const markerX: number = line.listMarkerX ?? 0;
        // 纸背透印：marker 图片按图片 alpha
        if (renderMode === 'backbleed') ctx.globalAlpha = this.BACK_BLEED_IMAGE_ALPHA;
        try {
          const src: string = line.markerImageSrc;
          if (src.startsWith('http://') || src.startsWith('https://')) {
            const cached: image.PixelMap | undefined = this.remoteImageCache.get(src);
            if (cached !== undefined) {
              ctx.drawImage(cached, markerX, y, markerSize, markerSize);
            }
          } else {
            // 本地图片 marker：异步解码缓存（仿 remoteImageCache 模式）
            const fullPath: string = this.resolveImagePath(this.bookBasePath, src);
            const cached: image.PixelMap | undefined = this.localImageCache.get(fullPath);
            if (cached !== undefined) {
              ctx.drawImage(cached, markerX, y, markerSize, markerSize);
            } else {
              this.preloadLocalImage(src);
            }
          }
        } catch (_e) { }
        if (renderMode === 'backbleed') ctx.globalAlpha = 1.0;
      }

      // 绘制 ruby 注音（如有）
      if (line.rubySegments !== undefined && line.rubySegments.length > 0) {
        // 用 base 字体测量宽度
        ctx.font = (fontSize * densityScale) + fontUnit + ' HarmonyOS Sans, sans-serif';
        const lp = this.engine.getLayoutProfile();
        for (let ri = 0; ri < line.rubySegments.length; ri++) {
          const seg: LineRubySegment = line.rubySegments[ri] as LineRubySegment;
          const prefix: string = line.text.substring(0, seg.baseStartIndex);
          const base: string = line.text.substring(seg.baseStartIndex, seg.baseEndIndex);
          const baseStartX: number = ctx.measureText(prefix).width;
          const baseWidth: number = ctx.measureText(base).width;
          RubyRenderer.drawRuby(ctx as CanvasRenderingContext2D, seg.rubyText, baseStartX, baseWidth,
            baselineY, fontSize, theme.textColor, {
            rubyFontFamily: lp.rubyFontFamily ?? 'HarmonyOS Sans',
            rubyColor: lp.rubyColor ?? '#888888',
            rubyFontSizeRatio: lp.rubyFontSizeRatio ?? 0.5,
            rubyPosition: seg.rubyPosition ?? 'over',
            rubyAlign: seg.rubyAlign ?? 'auto',
            unit: fontUnit
          } as RubyRenderOptions);
        }
        // 恢复 fillStyle
        ctx.fillStyle = theme.textColor;
      }

      // ── Opacity/BackBleed: restore globalAlpha ──
      if (textAlpha < 1) {
        ctx.globalAlpha = 1.0;
      }

      // Command 2: 恢复 Canvas 上下文（如果之前 save/clip 过）
      if (needsClip) ctx.restore();

      y += lineAdvance;
    }

    // ── Annotation Render Overlay ──
    if (this.getAnnotations().length > 0) {
      AnnotationRenderer.render(ctx as CanvasRenderingContext2D, page.lines, this.getAnnotations(), fontSize, fontUnit);
    }

    // ── Text Selection Overlay ──
    if (this.getSelection() !== null) {
      SelectionRenderer.renderSelection(ctx as CanvasRenderingContext2D, this.getSelection()!, page.lines);
    }

    // ── Media Overlay Highlight Overlay ──
    const moController = this.engine.getMediaOverlayController();
    const moState = moController.getState();
    if (moState.highlightBounds.length > 0) {
      const savedFill: string | number | CanvasGradient | CanvasPattern = ctx.fillStyle;
      // ⚠ 不读回 globalAlpha（鸿蒙 getter 恒返回 undefined）：显式设置 0.3
      //    后强制复位 1.0，避免把 undefined 写回导致后续绘制透明污染。
      ctx.globalAlpha = 0.3;
      for (let hi = 0; hi < moState.highlightBounds.length; hi++) {
        const hb = moState.highlightBounds[hi];
        ctx.fillStyle = hb.color;
        ctx.fillRect(hb.x, hb.y, hb.width, hb.height);
      }
      ctx.globalAlpha = 1.0;
      ctx.fillStyle = savedFill;
    }
    ctx.restore();
  }

  /**
   * 异步加载远程图片到缓存
   */
  private loadRemoteImage(url: string): void {
    const doFetch = async (): Promise<void> => {
      try {
        let loader: RemoteResourceLoader = this.resourceLoader!;
        if (loader === null) {
          loader = this.engine.getRemoteResourceLoader();
          this.resourceLoader = loader;
        }
        const pixelMap: image.PixelMap | null = await loader.fetchImage(url, this.requestCanceller);
        if (pixelMap !== null && !this.disposed) {
          // FlipSession 冻结：翻页动画期间不更新纹理缓存（保持动画帧一致，
          // 动画结束后重绘会重新触发加载）
          if (this.isFlipActive !== null && this.isFlipActive()) {
            return;
          }
          this.remoteImageCache.set(url, pixelMap);
          // 触发页面重绘
          if (this.onContentChanged !== null) {
            this.onContentChanged();
          } else {
            this.renderPage();
          }
        }
      } catch (_e) {
      }
    };
    doFetch();
  }

  /**
   * 按图片原始比例等比缩放绘制，在可用区域内最大化居中。
   *
   * @param ctx Canvas 上下文
   * @param pixelMap 解码后的图片
   * @param x 可用区域左上角 x（vp）
   * @param y 可用区域左上角 y（vp）
   * @param availW 可用区域宽（vp）
   * @param availH 可用区域高（vp）
   */
  private drawImageScaled(ctx: CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D, pixelMap: image.PixelMap,
    x: number, y: number, availW: number, availH: number): void {
    try {
      // 获取原始像素尺寸
      const info: image.ImageInfo = pixelMap.getImageInfoSync();
      const origW: number = info.size.width;
      const origH: number = info.size.height;
      if (origW <= 0 || origH <= 0) {
        ctx.drawImage(pixelMap, x, y, availW, availH);
        return;
      }
      // 等比缩放：取"宽度占满"或"高度占满"中较小的比例（contain）
      const scale: number = Math.min(availW / origW, availH / origH);
      const drawW: number = origW * scale;
      const drawH: number = origH * scale;
      // 居中
      const drawX: number = x + (availW - drawW) / 2;
      const drawY: number = y + (availH - drawH) / 2;
      ctx.drawImage(pixelMap, drawX, drawY, drawW, drawH);
    } catch (_e) {
      ctx.drawImage(pixelMap, x, y, availW, availH);
    }
  }

  /**
   * 异步加载本地图片到缓存（缓存键 = resolveImagePath 全路径）
   */
  preloadLocalImage(src: string): void {
    const doLoad = async (): Promise<void> => {
      try {
        const fullPath: string = this.resolveImagePath(this.bookBasePath, src);
        if (this.localImageCache.has(fullPath)) {
          return; // 缓存命中，跳过
        }
        const source: image.ImageSource = image.createImageSource(fullPath);
        const pixelMap: image.PixelMap = await source.createPixelMap();
        if (!this.disposed) {
          // FlipSession 冻结：翻页动画期间不更新纹理缓存（保持动画帧一致，
          // 动画结束后重绘会重新触发加载）
          if (this.isFlipActive !== null && this.isFlipActive()) {
            return;
          }
          this.localImageCache.set(fullPath, pixelMap);
          // 触发页面重绘
          if (this.onContentChanged !== null) {
            this.onContentChanged();
          } else {
            this.renderPage();
          }
        }
      } catch (_e) {
      }
    };
    doLoad();
  }

  /**
   * 预取当前页所有远程图片
   */
  prefetchRemoteImages(lines: LineBox[]): void {
    for (let i = 0; i < lines.length; i++) {
      const src: string | undefined = lines[i].imageSrc;
      if (src !== undefined && (src.startsWith('http://') || src.startsWith('https://'))) {
        if (!this.remoteImageCache.has(src)) {
          this.loadRemoteImage(src);
        }
      }
      // 也预取 list-style-image
      const markerSrc: string | undefined = lines[i].markerImageSrc;
      if (markerSrc !== undefined && (markerSrc.startsWith('http://') || markerSrc.startsWith('https://'))) {
        if (!this.remoteImageCache.has(markerSrc)) {
          this.loadRemoteImage(markerSrc);
        }
      }
    }
  }

  /**
   * 预取下一页（currentGlobalPage + 1）的图片，为快速翻页做准备
   */
  prefetchNextPageImages(): void {
    // getGlobalPageNumber() 是 1-based，下一页索引 = 当前页号（即 0-based 的下一页）
    const nextIndex: number = this.engine.getGlobalPageNumber();
    const nextPage = this.engine.getPageByGlobalIndex(nextIndex);
    if (nextPage !== undefined) {
      for (let i = 0; i < nextPage.lines.length; i++) {
        const src: string | undefined = nextPage.lines[i].imageSrc;
        if (src !== undefined && src.length > 0 && !(src.startsWith('http://') || src.startsWith('https://'))) {
          this.preloadLocalImage(src);
        }
      }
    }
  }

  /**
   * Phase 10 S3：预取上一页（currentGlobalPage - 1）的图片。
   * 与 prefetchNextPageImages 对称——修复「冷启动只预取 N+1、从不预取 N-1」的资产不对称。
   */
  prefetchPreviousPageImages(): void {
    // getGlobalPageNumber() 是 1-based，上一页索引 = 当前页号 - 2
    const prevIndex: number = this.engine.getGlobalPageNumber() - 2;
    if (prevIndex < 0) {
      return;
    }
    const prevPage = this.engine.getPageByGlobalIndex(prevIndex);
    if (prevPage !== undefined) {
      for (let i = 0; i < prevPage.lines.length; i++) {
        const src: string | undefined = prevPage.lines[i].imageSrc;
        if (src !== undefined && src.length > 0 && !(src.startsWith('http://') || src.startsWith('https://'))) {
          this.preloadLocalImage(src);
        }
      }
    }
  }

  resolveImagePath(basePath: string, relativePath: string): string {
    // 绝对路径直接返回（CBZ 解析器产出的 href/imageSrc 是 /data/... 全路径；
    // 与 basePath 拼接会得到 basePath + '/data/...' 的错误路径）
    if (relativePath.startsWith('/')) {
      return relativePath;
    }
    const segments: string[] = relativePath.split('/');
    const result: string[] = [];
    for (let i = 0; i < segments.length; i++) {
      if (segments[i] === '..') {
        if (result.length > 0) result.pop();
      } else if (segments[i] !== '.') {
        result.push(segments[i]);
      }
    }
    return basePath + '/' + result.join('/');
  }
}
