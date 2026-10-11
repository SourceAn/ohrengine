import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { readerIsDark } from './ReaderTheme.ets';

/**
 * 底部菜单胶囊的沉浸光感强度档位（low / medium / high）。
 * 影响沉浸式系统材质的厚度、交互形变、光感反馈与降级底色透明度。
 */
export enum LightIntensity {
  LOW = 'low',
  MEDIUM = 'medium',
  HIGH = 'high'
}

/**
 * 胶囊材质降级策略（设备不支持 API 26 沉浸光感时按此档位自动降级）：
 * - immersiveLight：优先沉浸式系统材质（设备支持时直接生效）；
 * - blurMaterial：玻璃模糊 + 半透明底色（保底半透明材质感 / 背景融合感）；
 * - translucentFallback：仅半透明底色（保留背景融合与胶囊层级感）；
 * - solidFallback：实色底色（最低保底，避免退化为纯透明无法辨认）。
 */
export enum LightMaterialMode {
  IMMERSIVE_LIGHT = 'immersiveLight',
  BLUR_MATERIAL = 'blurMaterial',
  TRANSLUCENT_FALLBACK = 'translucentFallback',
  SOLID_FALLBACK = 'solidFallback'
}

/**
 * 沉浸光感材质统一配置（全局唯一入口）。
 *
 * - 能力检测：hdsMaterial.getSystemMaterialTypes() 查询设备支持的材质类型，
 *   仅当支持 MaterialType.IMMERSIVE 时为组件设置沉浸式系统材质。
 * - 材质预设：基于 systemMaterial 通用属性 + uiMaterial.ImmersiveMaterial，
 *   统一开启 interactive 交互形变与 lightEffect 光感反馈（最强档配置）。
 * - 沉浸式系统材质会自动影响背景色、边框、阴影与材质滤镜，并随设备算力
 *   与用户系统设置的沉浸光感强度自适应，无需手动降级。
 *
 * 升级说明：API 26 前（6.1.1/24）的 backdropBlur 玻璃回退方案已废弃，
 * 全部浮层统一走 systemMaterial。
 */
export class MaterialConfig {
  private static detected: boolean = false;
  private static immersiveSupported: boolean = false;

  /** 底部菜单胶囊沉浸光感强度（默认 HIGH，最高档） */
  static menuLightIntensity: LightIntensity = LightIntensity.HIGH;
  /** 设备不支持沉浸光感时的自动降级档位（默认 blurMaterial，优先保留材质质感） */
  static menuFallbackMode: LightMaterialMode = LightMaterialMode.BLUR_MATERIAL;

  /** 惰性执行一次设备材质能力检测（失败视为不支持） */
  static ensureDetected(): void {
    if (MaterialConfig.detected) {
      return;
    }
    try {
      // 双重判据：
      // 1) uiMaterial.ImmersiveStyle 命名空间成员实际存在（API 26 起才有；
      //    部分 OpenHarmony 设备 getSystemMaterialTypes 返回 IMMERSIVE 但该成员缺失）；
      // 2) hds 材质类型包含 IMMERSIVE。
      const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
      MaterialConfig.immersiveSupported = uiMaterial.ImmersiveStyle !== undefined
        && types.includes(hdsMaterial.MaterialType.IMMERSIVE);
    } catch (err) {
      MaterialConfig.immersiveSupported = false;
    }
    MaterialConfig.detected = true;
  }

  /** 设备是否支持沉浸式系统材质 */
  static isImmersiveSupported(): boolean {
    MaterialConfig.ensureDetected();
    return MaterialConfig.immersiveSupported;
  }

  /** 统一调整底部菜单胶囊的沉浸光感强度 */
  static setMenuLightIntensity(intensity: LightIntensity): void {
    MaterialConfig.menuLightIntensity = intensity;
  }

  /** 统一调整不支持沉浸光感时的降级策略 */
  static setMenuFallbackMode(mode: LightMaterialMode): void {
    MaterialConfig.menuFallbackMode = mode;
  }

  /** 当前实际生效的胶囊材质模式（设备支持时固定沉浸光感，否则取配置的降级档） */
  static currentMenuMaterialMode(): LightMaterialMode {
    if (MaterialConfig.isImmersiveSupported()) {
      return LightMaterialMode.IMMERSIVE_LIGHT;
    }
    return MaterialConfig.menuFallbackMode;
  }

  /** 胶囊沉浸式系统材质（按强度档位生成；设备不支持时返回 undefined，由调用方走 API24 平替） */
  static menuCapsuleMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    const rich: boolean = MaterialConfig.menuLightIntensity !== LightIntensity.LOW;
    return new uiMaterial.ImmersiveMaterial({
      style: MaterialConfig.menuStyleForIntensity(),
      materialColor: Color.Transparent,
      colorInvert: false,
      applyShadow: rich,
      interactive: rich,
      lightEffect: rich ? { color: undefined } : null
    });
  }

  /** 胶囊背景占位色：沉浸光感生效时置透明（由材质接管），否则按降级档位提供底色 */
  static menuCapsuleBgColor(): string {
    const mode: LightMaterialMode = MaterialConfig.currentMenuMaterialMode();
    if (mode === LightMaterialMode.IMMERSIVE_LIGHT) {
      return '#00000000';
    }
    if (mode === LightMaterialMode.SOLID_FALLBACK) {
      return '#E1E1E1';
    }
    return MaterialConfig.menuTranslucentColor();
  }

  /** 胶囊背景模糊（仅 blurMaterial 档生效，其余档位关闭以避免与材质滤镜重复） */
  static menuCapsuleBlurStyle(): BlurStyle {
    if (MaterialConfig.currentMenuMaterialMode() !== LightMaterialMode.BLUR_MATERIAL) {
      return BlurStyle.NONE;
    }
    switch (MaterialConfig.menuLightIntensity) {
      case LightIntensity.LOW:
        return BlurStyle.BACKGROUND_THIN;
      case LightIntensity.HIGH:
        return BlurStyle.BACKGROUND_THICK;
      default:
        return BlurStyle.BACKGROUND_REGULAR;
    }
  }

  private static menuStyleForIntensity(): uiMaterial.ImmersiveStyle {
    switch (MaterialConfig.menuLightIntensity) {
      case LightIntensity.HIGH:
        return uiMaterial.ImmersiveStyle.THIN;
      case LightIntensity.MEDIUM:
        return uiMaterial.ImmersiveStyle.ULTRA_THIN;
      default:
        return uiMaterial.ImmersiveStyle.ULTRA_THIN;
    }
  }

  private static menuTranslucentColor(): string {
    if (readerIsDark()) {
      switch (MaterialConfig.menuLightIntensity) {
        case LightIntensity.LOW:
          return '#66FFFFFF';
        case LightIntensity.HIGH:
          return '#99FFFFFF';
        default:
          return '#80FFFFFF';
      }
    }
    switch (MaterialConfig.menuLightIntensity) {
      case LightIntensity.LOW:
        return '#4DE1E1E1';
      case LightIntensity.HIGH:
        return '#80E1E1E1';
      default:
        return '#66E1E1E1';
    }
  }

  /**
   * 顶部圆形玻璃按钮：超薄材质（高度通透、透射环境色）、
   * 自动反色保可读性、开启交互形变与光感反馈。
   */
  static topButtonMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: Color.Transparent,
      colorInvert: true,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: undefined }
    });
  }

  /** 底部悬浮菜单栏 / 自动翻页栏：薄材质，通透且具备明显玻璃层次 */
  static floatingBarMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Color.Transparent,
      colorInvert: false,
      applyShadow: true,
      interactive: false,
      lightEffect: { color: undefined }
    });
  }

  /** 目录 / 设置底部抽屉：薄材质，通透且保留较强模糊层次 */
  static sheetMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: 'rgba(255,255,255,0.06)',
      colorInvert: false,
      applyShadow: true,
      interactive: false,
      lightEffect: { color: undefined }
    });
  }

  /** 小型悬浮卡片（字体 / 背景子面板 / 长按菜单）：薄材质 */
  static cardMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Color.Transparent,
      colorInvert: false,
      applyShadow: true,
      interactive: false,
      lightEffect: { color: undefined }
    });
  }

  /** 行内次级胶囊（未选中态）：超薄材质 + 轻交互反馈 */
  static capsuleMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: Color.Transparent,
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: undefined }
    });
  }

  /**
   * 底部菜单胶囊材质（深色模式与顶部返回按钮统一：超薄透明玻璃、无背景色；
   * 浅色模式保持原沉浸光感胶囊）。
   */
  static menuCapsuleThemeMaterial(isDark: boolean): uiMaterial.Material | undefined {
    return isDark ? MaterialConfig.topButtonMaterial() : MaterialConfig.menuCapsuleMaterial();
  }

  /** 底部菜单胶囊背景占位色（深色模式置透明，完全无背景） */
  static menuCapsuleThemeBg(isDark: boolean): string {
    return isDark ? '#00000000' : MaterialConfig.menuCapsuleBgColor();
  }

  /** 底部菜单胶囊背景模糊（深色模式关闭，与顶部按钮一致） */
  static menuCapsuleThemeBlur(isDark: boolean): BlurStyle {
    return isDark ? BlurStyle.NONE : MaterialConfig.menuCapsuleBlurStyle();
  }

  /** 空材质对象（用于显式关闭某组件的沉浸光感；设备不支持时返回 undefined） */
  static empty(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return uiMaterial.Material.empty;
  }

  /** 主强调色 */
  static accent(): string {
    return '#2679E8';
  }

  // ──────────────────────────────────────────────────────────────────────────────
  // API 24 平替组（设备不支持沉浸式系统材质时使用）：
  // 用「半透明底色 + 背景模糊」近似对应档位 ImmersiveMaterial 的玻璃质感。
  // 全部为「模式感知」：沉浸光感生效时返回透明 / 无模糊（由 systemMaterial 接管），
  // 因此可在属性链中无条件调用，与 .systemMaterial() 共存，无需调用方分支。
  // ──────────────────────────────────────────────────────────────────────────────

  /** 顶部圆形玻璃按钮底色（API 24：白玻同书架分段胶囊 #D9FFFFFF + 深色深灰玻，近似 ULTRA_THIN + colorInvert） */
  static topButtonBg(): string {
    if (MaterialConfig.isImmersiveSupported()) {
      return '#00000000';
    }
    return readerIsDark() ? '#4D4F52' : '#D9FFFFFF';
  }

  /** 顶部圆形玻璃按钮模糊（API 24：强模糊，参考书架分段胶囊 backdropBlur 40） */
  static topButtonBlur(): BlurStyle {
    if (MaterialConfig.isImmersiveSupported()) {
      return BlurStyle.NONE;
    }
    return BlurStyle.BACKGROUND_THICK;
  }

  /** 底部悬浮菜单栏 / 自动翻页栏底色（API 24：白玻 + 深色深灰玻，近似 THIN 沉浸材质） */
  static floatingBarBg(): string {
    if (MaterialConfig.isImmersiveSupported()) {
      return '#00000000';
    }
    return readerIsDark() ? '#2E2E30E6' : '#E8FFFFFF';
  }

  /** 底部悬浮菜单栏 / 自动翻页栏模糊（API 24：常规模糊） */
  static floatingBarBlur(): BlurStyle {
    if (MaterialConfig.isImmersiveSupported()) {
      return BlurStyle.NONE;
    }
    return BlurStyle.BACKGROUND_REGULAR;
  }

  /** 目录 / 设置底部抽屉底色（API 24：白玻 + 深色深灰玻，近似 THIN 沉浸材质） */
  static sheetBg(): string {
    if (MaterialConfig.isImmersiveSupported()) {
      return '#00000000';
    }
    return readerIsDark() ? '#1C1C1EF2' : '#F0FFFFFF';
  }

  /** 目录 / 设置底部抽屉模糊（API 24：常规模糊） */
  static sheetBlur(): BlurStyle {
    if (MaterialConfig.isImmersiveSupported()) {
      return BlurStyle.NONE;
    }
    return BlurStyle.BACKGROUND_REGULAR;
  }

  /** 小型悬浮卡片底色（API 24：白玻 + 深色深灰玻，近似 THIN 沉浸材质） */
  static cardBg(): string {
    if (MaterialConfig.isImmersiveSupported()) {
      return '#00000000';
    }
    return readerIsDark() ? '#2E2E30E6' : '#E8FFFFFF';
  }

  /** 小型悬浮卡片模糊（API 24：强模糊，参考保存按钮 backdropBlur 40） */
  static cardBlur(): BlurStyle {
    if (MaterialConfig.isImmersiveSupported()) {
      return BlurStyle.NONE;
    }
    return BlurStyle.BACKGROUND_THICK;
  }

  /** 行内次级胶囊底色（API 24：白玻 + 深色深灰玻，参考长胶囊底座 #14FFFFFF + blur 50） */
  static capsuleBg(): string {
    if (MaterialConfig.isImmersiveSupported()) {
      return '#00000000';
    }
    return readerIsDark() ? '#3A3C3E' : '#33FFFFFF';
  }

  /** 行内次级胶囊模糊（API 24：强模糊） */
  static capsuleBlur(): BlurStyle {
    if (MaterialConfig.isImmersiveSupported()) {
      return BlurStyle.NONE;
    }
    return BlurStyle.BACKGROUND_REGULAR;
  }

  /** 阅读进度轨道底色（API 24：灰底，深浅色通用，不模糊） */
  static scrubTrackBg(): string {
    if (MaterialConfig.isImmersiveSupported()) {
      return '#00000000';
    }
    return readerIsDark() ? 'rgba(150,158,168,0.28)' : 'rgba(116,124,132,0.24)';
  }

  /** 强档沉浸光感（THICK；书架分段指示层等强光场景；API 24 返回 undefined） */
  static strongMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THICK,
      lightEffect: { color: undefined }
    });
  }

  /** 白色强档沉浸光感（保存按钮等白玻场景；THICK + 白玻色 + 白色光感；API 24 返回 undefined） */
  static strongWhiteMaterial(): uiMaterial.Material | undefined {
    if (!MaterialConfig.isImmersiveSupported()) {
      return undefined;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THICK,
      materialColor: '#E8FFFFFF',
      lightEffect: { color: '#66FFFFFF' }
    });
  }
}