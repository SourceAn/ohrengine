/**
 * MaterialScopeCommon — 沉浸光感清单探针公共工具。
 */
import { uiMaterial } from '@kit.ArkUI';

/** 探针材质：显式开启沉浸光感（不加赋色，避免遮挡材质滤镜） */
export function probeMaterial(style: uiMaterial.ImmersiveStyle): uiMaterial.Material {
  return new uiMaterial.ImmersiveMaterial({
    style: style,
    colorInvert: false,
    applyShadow: true
  });
}