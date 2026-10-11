/**
 * TxtEncodingDetector — TXT 文本编码自动检测
 *
 * 中文网络书籍常见编码为 GBK/GB2312/GB18030，而旧实现固定按 UTF-8
 * 解码，GBK 文件会出现乱码。本检测器策略：
 *
 *   1. BOM 优先：UTF-8 / UTF-16LE / UTF-16BE 的 BOM 直接判定；
 *   2. 无 BOM 时对采样字节做严格 UTF-8 合法性扫描：
 *      - 全部合法（含纯 ASCII）→ 'utf-8'；
 *      - 存在非法序列 → 'gb18030'（GB18030 向下兼容 GBK/GB2312，
 *        且是 Unicode 全集映射，作为中文回退编码最稳妥）。
 */

import { TxtConfig } from './TxtConfig.ets';

export class TxtEncodingDetector {
  private static readonly BOM_UTF8_0: number = 0xEF;
  private static readonly BOM_UTF8_1: number = 0xBB;
  private static readonly BOM_UTF8_2: number = 0xBF;
  private static readonly BOM_UTF16LE_0: number = 0xFF;
  private static readonly BOM_UTF16LE_1: number = 0xFE;
  private static readonly BOM_UTF16BE_0: number = 0xFE;
  private static readonly BOM_UTF16BE_1: number = 0xFF;

  /**
   * 检测给定字节流的文本编码。
   *
   * @param bytes - 原始文件字节（或头部采样）
   * @returns 可传给 util.TextDecoder.create() 的编码名
   */
  public static detect(bytes: Uint8Array): string {
    if (bytes.length >= 3 &&
      bytes[0] === TxtEncodingDetector.BOM_UTF8_0 &&
      bytes[1] === TxtEncodingDetector.BOM_UTF8_1 &&
      bytes[2] === TxtEncodingDetector.BOM_UTF8_2) {
      return 'utf-8';
    }
    if (bytes.length >= 2 &&
      bytes[0] === TxtEncodingDetector.BOM_UTF16LE_0 &&
      bytes[1] === TxtEncodingDetector.BOM_UTF16LE_1) {
      return 'utf-16le';
    }
    if (bytes.length >= 2 &&
      bytes[0] === TxtEncodingDetector.BOM_UTF16BE_0 &&
      bytes[1] === TxtEncodingDetector.BOM_UTF16BE_1) {
      return 'utf-16be';
    }
    return TxtEncodingDetector.isValidUtf8(bytes) ? 'utf-8' : 'gb18030';
  }

  /**
   * 严格 UTF-8 合法性扫描。
   *
   * 检查每个多字节序列的引导字节与后续连续字节的合法性
   * （不校验 overlong/代理细节——那些在真实中文书籍场景中
   * 出现概率可忽略，误判代价低且仅影响编码选择）。
   */
  private static isValidUtf8(bytes: Uint8Array): boolean {
    const sampleLen: number =
      Math.min(bytes.length, TxtConfig.ENCODING_SAMPLE_BYTES);
    let i: number = 0;
    while (i < sampleLen) {
      const b: number = bytes[i];
      if (b < 0x80) {
        i++;
        continue;
      }
      let continuationCount: number = 0;
      if ((b & 0xE0) === 0xC0) {
        continuationCount = 1;
      } else if ((b & 0xF0) === 0xE0) {
        continuationCount = 2;
      } else if ((b & 0xF8) === 0xF0) {
        continuationCount = 3;
      } else {
        return false;
      }
      if (i + continuationCount >= sampleLen) {
        // 采样边界截断的多字节序列：无法判定，按合法处理
        break;
      }
      for (let k: number = 1; k <= continuationCount; k++) {
        const cb: number = bytes[i + k];
        if ((cb & 0xC0) !== 0x80) {
          return false;
        }
      }
      i += continuationCount + 1;
    }
    return true;
  }
}
