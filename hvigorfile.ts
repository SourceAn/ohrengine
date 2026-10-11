/**
 * 工程级 hvigorfile（项目安全整改 SEC-001 / ENG-012）
 *
 * 签名配置策略：
 * - `build-profile.json5`（已跟踪）不包含任何签名密码、私钥密码或个人绝对路径，
 *   因此公共仓库中的构建产物默认是 unsigned。
 * - 若本机存在 `signing/signing-config.json5`（该路径已被 .gitignore 忽略，
 *   不会提交敏感信息），则通过 hvigorfile 的 `overrides` 机制将其注入签名配置，
 *   使本地可产出已签名的 Debug/Release 包。
 * - 无本地签名配置文件时构建仍可正常完成（产物为 unsigned）。
 *
 * Debug/Release 入口分离（ENG-012）：
 * - 在构建期根据 buildMode 生成 `entry/src/main/ets/BuildProfile.ets`
 *   （BUILD_MODE 常量），供 EntryAbility 在编译期选择入口页面：
 *     debug   → debug/DebugBookshelf
 *     release → pages/Bookshelf
 * - 这是构建期常量注入，不是运行时字符串判断；Release 产物不携带调试分支。
 * - buildProfileFields（build-profile.json5）在部分 SDK 工具链下不会注入到
 *   入口模块编译，因此采用本机制兜底。
 */
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { hvigorCore } from '@ohos/hvigor';
import * as fs from 'fs';
import * as path from 'path';

function loadLocalSigningConfig(): object | undefined {
  const cfgPath: string = path.join(__dirname, 'signing', 'signing-config.json5');
  if (!fs.existsSync(cfgPath)) {
    return undefined;
  }
  try {
    const raw: string = fs.readFileSync(cfgPath, 'utf8');
    const material = JSON.parse(raw);
    if (material && typeof material === 'object' &&
        material.storeFile && material.storePassword &&
        material.keyAlias && material.keyPassword &&
        material.signAlg && material.profile && material.certpath) {
      return {
        type: 'HarmonyOS',
        material: {
          storeFile: material.storeFile,
          storePassword: material.storePassword,
          keyAlias: material.keyAlias,
          keyPassword: material.keyPassword,
          signAlg: material.signAlg,
          profile: material.profile,
          certpath: material.certpath
        }
      };
    }
    console.warn('[hvigorfile] signing/signing-config.json5 exists but is incomplete; falling back to unsigned build.');
    return undefined;
  } catch (e) {
    console.warn('[hvigorfile] failed to parse signing/signing-config.json5: ' + String(e));
    return undefined;
  }
}

/**
 * 根据构建模式生成 entry/src/main/ets/BuildProfile.ets（ENG-012）。
 * buildMode 取自 -p buildMode=debug|release，缺省按 release 处理（对外发布安全默认）。
 */
function writeBuildProfile(buildMode: string): void {
  const mode: string = buildMode === 'debug' ? 'debug' : 'release';
  const isDebug: boolean = mode === 'debug';
  const filePath: string = path.join(__dirname, 'entry', 'src', 'main', 'ets', 'BuildProfile.ets');
  const content: string =
    '/**\n' +
    ' * BuildProfile — 构建期常量（ENG-012）\n' +
    ' *\n' +
    ' * 由 hvigorfile.ts 在构建期根据 buildMode 自动生成。\n' +
    ' * 用于 Debug/Release 入口分离：debug → DebugBookshelf，release → Bookshelf。\n' +
    ' * 构建期静态确定，非运行时字符串判断。\n' +
    ' */\n' +
    "export const BUILD_MODE = '" + mode + "';\n" +
    'export const DEBUG = ' + (isDebug ? 'true' : 'false') + ';\n' +
    '\n' +
    'export default class BuildProfile {\n' +
    '  static readonly BUILD_MODE = BUILD_MODE;\n' +
    '  static readonly DEBUG = DEBUG;\n' +
    '}\n';
  try {
    fs.writeFileSync(filePath, content, 'utf8');
    console.log('[hvigorfile] generated BuildProfile.ets BUILD_MODE=' + mode);
  } catch (e) {
    console.warn('[hvigorfile] failed to write BuildProfile.ets: ' + String(e));
  }
}

const signingConfig: object | undefined = loadLocalSigningConfig();
const config: Record<string, object> = {};
if (signingConfig !== undefined) {
  config['ohos'] = {
    overrides: {
      signingConfig: signingConfig
    }
  };
}

// 构建期注入 BUILD_MODE（ENG-012）
// buildMode 通过 hvigorCore.getExtraConfig().get('buildMode') 获取
// （与 hvigor-ohos-plugin 内部 getBuildModeName 同源）。
let buildMode: string = 'release';
try {
  const mode: unknown = hvigorCore.getExtraConfig().get('buildMode');
  if (typeof mode === 'string' && mode.length > 0) {
    buildMode = mode;
  }
} catch (e) {
  console.warn('[hvigorfile] failed to read buildMode, defaulting to release: ' + String(e));
}
writeBuildProfile(buildMode);

export default {
    system: appTasks,
    plugins: [],
    config: config
};
