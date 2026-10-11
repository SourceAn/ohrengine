/**
 * TxtIndexBuilderTask — TXT 索引 TaskPool 构建（P0-A）
 *
 * 与 TxtIndexBuilder 解耦的独立模块：@Concurrent 函数只能使用 import/local 变量，
 * 不能直接引用同模块类静态（编译器约束），故把 worker 入口放在独立文件。
 *
 * 效果：200MB TXT 首次索引构建在 TaskPool worker 执行，不冻结 UI/JS 主线程；
 * worker 不可用/异常时自动回退 TxtIndexBuilder.build（主线程旧路径，保持正确性）。
 */
import { taskpool } from '@kit.ArkTS';
import { TxtIndexBuilder } from './TxtIndexBuilder.ets';
import { TxtIndexData } from './TxtIndexData.ets';

/**
 * TaskPool worker 入口：构建索引并返回 JSON 字符串（结构化克隆安全）。
 */
@Concurrent
export async function buildTxtIndexConcurrent(filePath: string): Promise<string | null> {
  try {
    const idx: TxtIndexData | null = await TxtIndexBuilder.build(filePath);
    return idx === null ? null : idx.toJson();
  } catch (_e) {
    return null;
  }
}

/**
 * TaskPool 构建封装：execute worker → 反序列化 TxtIndexData；异常回退主线程 build。
 */
export class TxtIndexBuilderTask {
  public static async buildInTaskPool(filePath: string): Promise<TxtIndexData | null> {
    try {
      const result: Object = await taskpool.execute(buildTxtIndexConcurrent, filePath);
      if (typeof result === 'string' && result.length > 0) {
        return TxtIndexData.fromJson(result);
      }
      return null;
    } catch (_e) {
      // worker 环境不可用 → 回退原路径（保持正确性）
      return TxtIndexBuilder.build(filePath);
    }
  }
}