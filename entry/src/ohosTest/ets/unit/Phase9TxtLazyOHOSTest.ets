/**
 * Phase9TxtLazyOHOSTest — TXT 惰性数据源（Phase 9）一致性测试
 *
 * 覆盖（9.1–9.5 gate）：
 *   1) 索引构建 + chunk 随机读取；
 *   2) lazy vch HTML 与 eager（TxtParser.parse → buildVChapters）逐 vch 一致
 *      （这是 ReadingAnchor/paragraphHash 保持有效的前提）；
 *   3) vch HTML 确定性（重复读取同一 vch 结果一致）；
 *   4) paragraphHash 稳定性。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { TxtParser, TxtIndexBuilder, TxtDocument } from 'ohrengine-txt-exclusive';
import type { TxtIndexData } from 'ohrengine-txt-exclusive';
import { buildVChapters, extractParagraphs, hashParagraphText } from 'ohrengine-common';
import type { VChapterDef } from 'ohrengine-common';

const DIR: string = '/data/test/txtlazy';
const FILE: string = DIR + '/sample.txt';

function writeSample(count: number): void {
  try { fileIo.mkdirSync(DIR, true); } catch (_e) { }
  const parts: string[] = [];
  for (let c = 0; c < count; c++) {
    parts.push('第' + String(c + 1) + '章');
    for (let p = 0; p < 20; p++) {
      let para: string = '段落内容段落内容段落内容。';
      while (para.length < 900) {
        para = para + '补足文字补足文字。';
      }
      parts.push(para);
    }
    parts.push('');
  }
  const f: fileIo.File = fileIo.openSync(FILE,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, parts.join('\n'));
  fileIo.closeSync(f);
}

/**
 * eager vchapters：复刻 OhEngineCore.expandTxtToVChapters 的核心链条
 * （parse→buildChapters→extractParagraphs→buildVChapters→html 拼接）。
 */
async function eagerVchHtmls(): Promise<string[]> {
  // 直接用 TxtParser 解析（eager 路径），再按章节展开为 vch HTML。
  // expandTxtToVChapters 是 engine 私有方法；此处用同一公共组件复刻其语义。
  const parser = new TxtParser();
  const parsed = await parser.parse(FILE);
  const out: string[] = [];
  let globalIdx: number = 0;
  for (let ci = 0; ci < parsed.chapters.length; ci++) {
    const ch = parsed.chapters[ci];
    const paragraphs = extractParagraphs(ch.content);
    const texts: string[] = [];
    for (let p = 0; p < paragraphs.length; p++) {
      texts.push('<p>' + paragraphs[p] + '</p>');
    }
    const defs = buildVChapters(globalIdx, paragraphs, texts);
    for (let v = 0; v < defs.length; v++) {
      out.push(defs[v].html);
      globalIdx++;
    }
  }
  return out;
}

export default function txtLazyTest() {
  describe('TxtLazyTest', () => {
    it('index_build_and_chunk_read_random_range', 0, async () => {
      writeSample(3);
      const idx: TxtIndexData | null = await TxtIndexBuilder.build(FILE);
      expect(idx).not().assertNull();
      if (idx === null) {
        return;
      }
      expect(idx.vchapters.length > 0).assertTrue();
      expect(idx.fileSize > 0).assertTrue();
      const v = idx.vchapters[0];
      expect(v.byteEnd > v.byteStart).assertTrue();
      const doc: TxtDocument | undefined = await TxtDocument.open(FILE, DIR);
      expect(doc).not().assertUndefined();
      if (doc === undefined) {
        return;
      }
      const html: string | undefined = doc.getVChapterHtml(0);
      expect(html !== undefined && html.length > 0).assertTrue();
      doc.release();
    });

    it('lazy_vch_html_equals_eager_expand', 0, async () => {
      writeSample(3); // 3 章 × 20 段 × ~900 字 → 多 vch，覆盖跨 vch 切分
      const eager: string[] = await eagerVchHtmls();
      expect(eager.length > 1).assertTrue();
      const doc: TxtDocument | undefined = await TxtDocument.open(FILE, DIR);
      expect(doc).not().assertUndefined();
      if (doc === undefined) {
        return;
      }
      const lazyCount: number = doc.getVChapterCount();
      expect(lazyCount).assertEqual(eager.length);
      // 逐 vch 内容字节一致（ReadingAnchor/paragraphHash 前提）
      const compareCount: number = Math.min(lazyCount, eager.length);
      for (let i = 0; i < compareCount; i++) {
        const lazy: string | undefined = doc.getVChapterHtml(i);
        const exp: string = eager[i];
        expect(lazy !== undefined).assertTrue();
        if (lazy !== undefined) {
          expect(lazy).assertEqual(exp);
        }
      }
      doc.release();
    });

    it('vch_html_reread_deterministic_and_paragraph_hash_stable', 0, async () => {
      writeSample(2);
      const doc: TxtDocument | undefined = await TxtDocument.open(FILE, DIR);
      expect(doc).not().assertUndefined();
      if (doc === undefined) {
        return;
      }
      const h1: string | undefined = doc.getVChapterHtml(0);
      const h2: string | undefined = doc.getVChapterHtml(0);
      expect(h1).assertEqual(h2);
      if (h1 !== undefined && h2 !== undefined && h1.length > 0) {
        const paras1: string[] = extractParagraphs(h1);
        const paras2: string[] = extractParagraphs(h2);
        expect(paras1.length).assertEqual(paras2.length);
        if (paras1.length > 0 && paras2.length > 0) {
          expect(hashParagraphText(paras1[0])).assertEqual(hashParagraphText(paras2[0]));
        }
      }
      doc.release();
    });
  });
}