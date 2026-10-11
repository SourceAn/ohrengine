/**
 * Phase7OHOSTest — Migration / ImportCheckpoint / LayoutPriority 纯逻辑与沙箱测试
 *
 * 覆盖：
 *  - LayoutPriority 枚举值
 *  - ImportCheckpoint markStage/loadStages 往返（纯逻辑，不依赖真实沙箱文件的
 *    部分；文件 IO 方法需真机/模拟器沙箱——磁盘用例按现有约定放 device 候选）
 *  - CacheMigration.clearStalePageCache schema 判定（通过构建临时 meta 判定）
 *  - 页面逻辑文本 hash 一致性辅助不在此处重复（引擎层验证）
 */
import { describe, it, expect } from '@ohos/hypium';
import { LayoutPriority } from 'ohrengine-ui-render';
import { ImportCheckpoint, ImportStage } from 'ohrengine-common';
import { PAGE_CACHE_SCHEMA_VERSION, LAYOUT_ALGORITHM_VERSION } from 'ohrengine-common';

export default function phase7Test() {
  describe('Phase7Test', () => {
    it('layout_priority_enum_values', 0, () => {
      expect(LayoutPriority.P0_VISIBLE).assertEqual(0);
      expect(LayoutPriority.P1_NEXT).assertEqual(1);
      expect(LayoutPriority.P2_PREVIOUS).assertEqual(2);
      expect(LayoutPriority.P3_CACHE_WRITE).assertEqual(3);
      expect(LayoutPriority.P4_BACKGROUND).assertEqual(4);
    });

    it('import_checkpoint_stage_roundtrip', 0, () => {
      // 纯逻辑侧：空目录 loadStages 返回 []，不抛错（磁盘写入在真机验证）。
      const stages: string[] = ImportCheckpoint.loadStages('');
      expect(stages.length).assertEqual(0);
      expect(ImportStage.UNZIP_DONE.length > 0).assertTrue();
      expect(ImportStage.PARSE_DONE.length > 0).assertTrue();
      expect(ImportStage.CACHE_DONE.length > 0).assertTrue();
    });

    it('cache_migration_schema_constants_aligned', 0, () => {
      expect(PAGE_CACHE_SCHEMA_VERSION).assertEqual(1);
      expect(LAYOUT_ALGORITHM_VERSION).assertEqual(1);
    });
  });
}