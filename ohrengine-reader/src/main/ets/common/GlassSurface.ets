/*
 * Copyright (c) 2025 OhEngine Authors.
 * Licensed under the Apache License, Version 2.0 (the "License").
 *
 * GlassSurface — 沉浸光感玻璃面（纯 ArkUI 复刻，独立组件可用，无宿主容器）。
 *
 * 背景：系统沉浸光感材质在「底部 TabBar / Navigation 标题栏」等官方区域才渲染，
 * 但 Tabs 底部 TabBar 的 barFloatingStyle 会给底栏额外套一层胶囊背景（无法去除）。
 * 为满足「两条独立长胶囊、无外层包裹」的需求，此处用纯 ArkUI 复刻沉浸观感：
 *   · backdropBlur 磨砂面  · 半透明底色（深浅分支）
 *   · 高光描边环  · 顶部内侧反光  · 柔和投影
 * API24 / API26 均可稳定显示，且不产生任何外层背景。
 *
 * 用法（尺寸经 props 传入，避免尾随闭包后接属性链）：
 *   GlassSurface({ dark: this.localDark, radius: 24, boxW: '100%', boxH: 48 }) {
 *     Row() { ... }.width('100%').height('100%')
 *   }
 */
@Component
export struct GlassSurface {
  /** 深色模式（决定描边 / 反光 / 底色强度） */
  @Prop dark: boolean = false;
  /** 圆角半径：胶囊=高/2 */
  @Prop radius: number = 22;
  /** 组件宽度（数字=vp，或 '100%' 撑满父级） */
  boxW: Length = '100%';
  /** 组件高度（数字=vp，或 '100%' 撑满父级） */
  boxH: Length = 44;

  @Builder
  private emptySlot() {
  }

  /** 内容插槽（尾随闭包） */
  @BuilderParam
  content: () => void = this.emptySlot;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 磨砂面 + 高光描边（光感边缘环）
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .backgroundBlurStyle(BlurStyle.BACKGROUND_REGULAR)
        .backgroundColor(this.dark ? '#33FFFFFF' : '#B3FFFFFF')
        .border({ width: 1, color: this.dark ? '#40FFFFFF' : '#E6FFFFFF' })

      // 顶部内侧反光（上缘最亮的沉浸光感特征）
      Column()
        .width('100%')
        .height('46%')
        .borderRadius({ topLeft: this.radius, topRight: this.radius })
        .linearGradient({
          angle: 180,
          colors: this.dark
            ? [['#33FFFFFF', 0.0], ['#00FFFFFF', 1.0]]
            : [['#59FFFFFF', 0.0], ['#00FFFFFF', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      // 内容
      this.content()
    }
    .width(this.boxW)
    .height(this.boxH)
    .shadow({
      radius: 4,
      color: this.dark ? '#33000000' : '#1A000000',
      offsetY: 1
    })
  }
}
