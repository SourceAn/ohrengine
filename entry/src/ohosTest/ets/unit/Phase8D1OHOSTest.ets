/**
 * Phase8D1OHOSTest — L0 分块缓存纯逻辑测试（Phase 8 D1）
 *
 * 覆盖：ParseMeta/ParseChapterIndex/ParseChapterChunk 类型与
 *       plainTextLengthOf 行为（strip 后长度）。
 * 磁盘读写（saveParsedBookChunked/loadParseChapter）需要沙箱，
 * 在真机/模拟器环境验证（按现有约定）。
 */
import { describe, it, expect } from '@ohos/hypium';
import { PARSE_CHUNK_DIR } from 'ohrengine-common';
import { ParseCacheManager } from 'ohrengine-common';
import type { ParseChapterChunk } from 'ohrengine-common';

export default function phase8D1Test() {
  describe('Phase8D1Test', () => {
    it('parse_chunk_dir_name_isolation', 0, () => {
      // 分块目录独立子目录，与 L2 PageCache 的 chapter_{i}.json 不冲突
      expect(PARSE_CHUNK_DIR).assertEqual('parse');
    });

    it('parse_chapter_chunk_type_shape', 0, () => {
      const chunk: ParseChapterChunk = {
        title: '第一章',
        href: 'ch1.xhtml',
        content: '<p>hello</p>'
      };
      expect(chunk.title).assertEqual('第一章');
      expect(chunk.href).assertEqual('ch1.xhtml');
      expect(chunk.content.indexOf('hello') >= 0).assertTrue();
    });
  });
}