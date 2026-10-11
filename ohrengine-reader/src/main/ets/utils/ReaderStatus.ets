/**
 * ReaderStatus — 阅读状态条数据源（实时时间 / 实时电量）
 */
import { batteryInfo, systemDateTime } from '@kit.BasicServicesKit';

/** 当前时间 HH:MM */
export function formatClock(): string {
  const t: number = systemDateTime.getTime();
  const d: Date = new Date(t);
  const hh: string = String(d.getHours()).padStart(2, '0');
  const mm: string = String(d.getMinutes()).padStart(2, '0');
  return hh + ':' + mm;
}

/** 当前电量百分比（无电池/异常时返回 '--%'） */
export function readBattery(): string {
  try {
    const soc: number = batteryInfo.batterySOC;
    if (isNaN(soc)) {
      return '--%';
    }
    return Math.round(soc) + '%';
  } catch (_e) {
    return '--%';
  }
}

/** 当前电量百分比数值（无电池/异常时返回 -1） */
export function readSoc(): number {
  try {
    const soc: number = batteryInfo.batterySOC;
    if (isNaN(soc)) {
      return -1;
    }
    return Math.round(soc);
  } catch (_e) {
    return -1;
  }
}

/** 是否正在充电（充电中 / 已充满均视为充电态，便于展示充电图标） */
export function readCharging(): boolean {
  try {
    const status: batteryInfo.BatteryChargeState = batteryInfo.chargingStatus;
    return status === batteryInfo.BatteryChargeState.ENABLE ||
      status === batteryInfo.BatteryChargeState.FULL;
  } catch (_e) {
    return false;
  }
}
