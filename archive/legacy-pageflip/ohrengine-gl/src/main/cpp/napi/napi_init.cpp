/*
 * napi_init.cpp — ohrengine-gl N-API 注册 + XComponent 回调 + 意图级 API 绑定
 *
 * 本文件职责（T025/T009）：
 *  - 常驻 TSFN 生命周期（T009）：OnSurfaceCreated 建立、OnSurfaceDestroyed 释放；
 *    beginGesture 检查可用性返回 TSFN_UNAVAILABLE（0.6/0.12）；
 *  - 意图级 API 绑定（T025）：beginGesture→BeginGestureResult、updateGesture、
 *    endGesture、cancelGesture、beginReboundRecovery、releaseTextureTransaction；
 *  - 完成回调 payload {token, result} 经常驻 TSFN 转发 ArkTS。
 *
 * 坐标契约（0.14）：所有位置参数为 Surface px（ArkTS 侧 glPx/glPy 之后）。
 */
#include <napi/native_api.h>

#include <string>
#include <memory>

#include "hilog/log.h"
#include "ace/xcomponent/native_interface_xcomponent.h"
#include "engine/gl_flip_engine.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "OhEngineGL"
#define LOG_DOMAIN 0x3900
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace {

using flipgl::GlFlipEngine;
using flipgl::FlipResult;
using flipgl::FlipStateMachine;

// ── 常驻 TSFN 状态（T009，随 Surface 生命周期） ───────────────────────
napi_env g_env = nullptr;
napi_ref g_completionRef = nullptr;       // JS 完成回调函数引用
napi_threadsafe_function g_tsfn = nullptr; // 常驻 TSFN
bool g_surfaceCreated = false;

// 纹理双槽 ping-pong（保留原 SetTextures 缓存语义，T023）
flipgl::TextureHandle g_frontTex[2] = {0, 0};
flipgl::TextureHandle g_backTex[2] = {0, 0};
std::string g_frontKeys[2];
std::string g_backKeys[2];
int g_activeSlot = 0;
int g_frontW[2] = {0, 0};
int g_frontH[2] = {0, 0};
int g_backW[2] = {0, 0};
int g_backH[2] = {0, 0};

struct CompletionPayload {
  int32_t token;
  int32_t result;  // 0=completed 1=rebound
};

// ── XComponent 生命周期回调 ─────────────────────────────────────────

void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
  (void)component;
  uint64_t width = 0;
  uint64_t height = 0;
  // surface 尺寸查询（FLIP-BOOT-001 语义保留在 backend Init 内）
  OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
  GlFlipEngine::GetInstance()->OnSurfaceCreated(window, static_cast<int>(width),
                                                static_cast<int>(height));
  g_surfaceCreated = true;
}

void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
  uint64_t width = 0;
  uint64_t height = 0;
  OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
  GlFlipEngine::GetInstance()->OnSurfaceChanged(window, static_cast<int>(width),
                                                static_cast<int>(height));
}

void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
  (void)component;
  (void)window;
  // Required Change 5 清理矩阵：TSFN 释放 + 引擎清理（状态机/事务/纹理）
  GlFlipEngine::GetInstance()->SetTsfnAvailable(false);
  if (g_tsfn != nullptr) {
    napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
    g_tsfn = nullptr;
  }
  g_surfaceCreated = false;
  GlFlipEngine::GetInstance()->OnSurfaceDestroyed();
  // 释放纹理句柄槽位
  for (int i = 0; i < 2; i++) {
    if (g_frontTex[i] != 0) {
      GlFlipEngine::GetInstance()->ReleaseTexture(g_frontTex[i]);
      g_frontTex[i] = 0;
    }
    if (g_backTex[i] != 0) {
      GlFlipEngine::GetInstance()->ReleaseTexture(g_backTex[i]);
      g_backTex[i] = 0;
    }
    g_frontKeys[i].clear();
    g_backKeys[i].clear();
  }
  g_activeSlot = 0;
}

// ── 常驻 TSFN 建立（T009） ──────────────────────────────────────────

void EnsureResidentTsfn() {
  if (g_tsfn != nullptr || g_env == nullptr || g_completionRef == nullptr) {
    return;
  }
  napi_value cb = nullptr;
  if (napi_get_reference_value(g_env, g_completionRef, &cb) != napi_ok || cb == nullptr) {
    LOGE("EnsureResidentTsfn: get completion cb failed");
    return;
  }
  napi_value resourceName = nullptr;
  napi_create_string_utf8(g_env, "ohrengine_gl_flip_complete", NAPI_AUTO_LENGTH, &resourceName);
  napi_status st = napi_create_threadsafe_function(
      g_env, cb, nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr,
      [](napi_env env, napi_value cbFn, void* /*ctx*/, void* data) {
        auto* payload = static_cast<CompletionPayload*>(data);
        if (payload != nullptr) {
          napi_value args[2] = {nullptr, nullptr};
          napi_create_int32(env, payload->token, &args[0]);
          const char* resultStr = payload->result == 0 ? "completed" : "rebound";
          napi_create_string_utf8(env, resultStr, NAPI_AUTO_LENGTH, &args[1]);
          napi_call_function(env, nullptr, cbFn, 2, args, nullptr);
          delete payload;
        }
      },
      &g_tsfn);
  if (st != napi_ok || g_tsfn == nullptr) {
    LOGE("EnsureResidentTsfn: TSFN create failed status=%{public}d", static_cast<int>(st));
    return;
  }
  GlFlipEngine::GetInstance()->SetTsfnAvailable(true);
  LOGI("EnsureResidentTsfn: resident TSFN established");
}

void FireCompletion(int32_t token, FlipResult result) {
  if (g_tsfn == nullptr) {
    LOGE("FireCompletion: tsfn_ is null (resident TSFN not available)");
    return;
  }
  auto* payload = new CompletionPayload();
  payload->token = token;
  payload->result = static_cast<int32_t>(result);
  napi_status st = napi_call_threadsafe_function(g_tsfn, payload, napi_tsfn_blocking);
  if (st != napi_ok) {
    LOGE("FireCompletion: TSFN call failed status=%{public}d", static_cast<int>(st));
    delete payload;
  }
}

// ── N-API 方法 ──────────────────────────────────────────────────────

napi_value Init(napi_env env, napi_callback_info info) {
  (void)info;
  g_env = env;
  bool ready = GlFlipEngine::GetInstance()->IsReady();
  LOGI("init() called, ready=%{public}d", ready ? 1 : 0);
  napi_value result = nullptr;
  napi_get_boolean(env, ready, &result);
  return result;
}

napi_value SetDisplayRefreshRate(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc >= 1) {
    int32_t rate = 60;
    if (napi_get_value_int32(env, args[0], &rate) == napi_ok) {
      GlFlipEngine::GetInstance()->SetDisplayRefreshRate(static_cast<int>(rate));
    }
  }
  return nullptr;
}

napi_value SetTextures(napi_env env, napi_callback_info info) {
  size_t argc = 8;
  napi_value args[8] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 8) {
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
  }
  void* frontData = nullptr;
  size_t frontLen = 0;
  void* backData = nullptr;
  size_t backLen = 0;
  napi_get_arraybuffer_info(env, args[0], &frontData, &frontLen);
  napi_get_arraybuffer_info(env, args[3], &backData, &backLen);
  int32_t fw = 0, fh = 0, bw = 0, bh = 0;
  napi_get_value_int32(env, args[1], &fw);
  napi_get_value_int32(env, args[2], &fh);
  napi_get_value_int32(env, args[4], &bw);
  napi_get_value_int32(env, args[5], &bh);
  char frontKeyBuf[512] = {0};
  char backKeyBuf[512] = {0};
  size_t frontKeyLen = 0;
  size_t backKeyLen = 0;
  napi_get_value_string_utf8(env, args[6], frontKeyBuf, sizeof(frontKeyBuf), &frontKeyLen);
  napi_get_value_string_utf8(env, args[7], backKeyBuf, sizeof(backKeyBuf), &backKeyLen);
  const std::string frontKey(frontKeyBuf);
  const std::string backKey(backKeyBuf);

  GlFlipEngine* eng = GlFlipEngine::GetInstance();
  if (!eng->IsReady()) {
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
  }
  // 缓存命中（双槽 ping-pong，与旧 SetTextures 语义一致）
  for (int i = 0; i < 2; i++) {
    if (g_frontKeys[i] == frontKey && g_backKeys[i] == backKey) {
      g_activeSlot = i;
      napi_value r = nullptr;
      napi_get_boolean(env, true, &r);
      return r;
    }
  }
  const int slot = g_activeSlot == 0 ? 1 : 0;
  if (g_frontTex[slot] != 0) {
    eng->ReleaseTexture(g_frontTex[slot]);
  }
  if (g_backTex[slot] != 0) {
    eng->ReleaseTexture(g_backTex[slot]);
  }
  g_frontTex[slot] = eng->UploadTexture(static_cast<const uint8_t*>(frontData), fw, fh);
  g_backTex[slot] = eng->UploadTexture(static_cast<const uint8_t*>(backData), bw, bh);
  if (g_frontTex[slot] == 0 || g_backTex[slot] == 0) {
    g_frontTex[slot] = 0;
    g_backTex[slot] = 0;
    napi_value r = nullptr;
    napi_get_boolean(env, false, &r);
    return r;
  }
  g_frontKeys[slot] = frontKey;
  g_backKeys[slot] = backKey;
  g_frontW[slot] = fw;
  g_frontH[slot] = fh;
  g_backW[slot] = bw;
  g_backH[slot] = bh;
  g_activeSlot = slot;
  LOGI("SetTextures: slot=%{public}d frontKey=%{public}s backKey=%{public}s",
       slot, frontKey.c_str(), backKey.c_str());
  napi_value r = nullptr;
  napi_get_boolean(env, true, &r);
  return r;
}

napi_value SetCompletionHandler(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) {
    return nullptr;
  }
  g_env = env;
  if (g_completionRef != nullptr) {
    napi_delete_reference(env, g_completionRef);
    g_completionRef = nullptr;
  }
  if (napi_create_reference(env, args[0], 1, &g_completionRef) != napi_ok) {
    LOGE("SetCompletionHandler: create ref failed");
    return nullptr;
  }
  // 完成回调 → 引擎 → 常驻 TSFN
  GlFlipEngine::GetInstance()->SetCompletionCallback(
      [](int32_t token, FlipResult result) { FireCompletion(token, result); });
  // 回调函数已更换（阅读器重进时新 controller 注册新闭包）：旧 TSFN 捕获的是旧函数，
  // 必须强制释放重建，否则完成回调会投递给已 dispose 的旧控制器（回归修复 2026-08-10）。
  if (g_tsfn != nullptr) {
    napi_release_threadsafe_function(g_tsfn, napi_tsfn_release);
    g_tsfn = nullptr;
  }
  if (g_surfaceCreated) {
    EnsureResidentTsfn();
  }
  LOGI("SetCompletionHandler: registered");
  return nullptr;
}

napi_value BeginGesture(napi_env env, napi_callback_info info) {
  size_t argc = 7;
  napi_value args[7] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 5) {
    napi_value r = nullptr;
    napi_get_null(env, &r);
    return r;
  }
  int32_t direction = 1;
  int32_t spine = 0;
  double downX = 0, downY = 0;
  int32_t model = 0;
  int32_t synthetic = 0;
  int32_t pageGen = 0;
  napi_get_value_int32(env, args[0], &direction);
  napi_get_value_int32(env, args[1], &spine);
  napi_get_value_double(env, args[2], &downX);
  napi_get_value_double(env, args[3], &downY);
  napi_get_value_int32(env, args[4], &model);
  if (argc >= 6) {
    napi_get_value_int32(env, args[5], &synthetic);
  }
  if (argc >= 7) {
    napi_get_value_int32(env, args[6], &pageGen);
  }
  const int slot = g_activeSlot;
  flipgl::BeginGestureResult result = GlFlipEngine::GetInstance()->BeginGesture(
      direction, spine == 1 ? flipgl::SpineSide::RIGHT : flipgl::SpineSide::LEFT,
      static_cast<float>(downX), static_cast<float>(downY),
      static_cast<flipgl::CurlModel>(model), synthetic != 0, pageGen,
      g_frontTex[slot], g_backTex[slot], g_frontW[slot], g_frontH[slot],
      g_backW[slot], g_backH[slot]);
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  napi_value vToken = nullptr;
  napi_value vSuccess = nullptr;
  napi_value vReason = nullptr;
  napi_create_int32(env, result.operationToken, &vToken);
  napi_get_boolean(env, result.success, &vSuccess);
  napi_create_int32(env, static_cast<int32_t>(result.failureReason), &vReason);
  napi_set_named_property(env, obj, "operationToken", vToken);
  napi_set_named_property(env, obj, "success", vSuccess);
  napi_set_named_property(env, obj, "failureReason", vReason);
  return obj;
}

napi_value UpdateGesture(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 4) {
    return nullptr;
  }
  int32_t token = 0;
  double x = 0, y = 0, ts = 0;
  napi_get_value_int32(env, args[0], &token);
  napi_get_value_double(env, args[1], &x);
  napi_get_value_double(env, args[2], &y);
  napi_get_value_double(env, args[3], &ts);
  GlFlipEngine::GetInstance()->UpdateGesture(token, static_cast<float>(x),
                                             static_cast<float>(y),
                                             static_cast<int64_t>(ts));
  return nullptr;
}

napi_value EndGesture(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    return nullptr;
  }
  int32_t token = 0;
  double x = 0, y = 0;
  napi_get_value_int32(env, args[0], &token);
  napi_get_value_double(env, args[1], &x);
  napi_get_value_double(env, args[2], &y);
  GlFlipEngine::GetInstance()->EndGesture(token, static_cast<float>(x),
                                          static_cast<float>(y));
  return nullptr;
}

napi_value CancelGesture(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) {
    return nullptr;
  }
  int32_t token = 0;
  napi_get_value_int32(env, args[0], &token);
  GlFlipEngine::GetInstance()->CancelGesture(token);
  return nullptr;
}

napi_value BeginReboundRecovery(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    napi_value r = nullptr;
    napi_get_null(env, &r);
    return r;
  }
  int32_t prevToken = 0;
  int32_t direction = 1;
  napi_get_value_int32(env, args[0], &prevToken);
  napi_get_value_int32(env, args[1], &direction);
  flipgl::BeginGestureResult result =
      GlFlipEngine::GetInstance()->BeginReboundRecovery(prevToken, direction);
  napi_value obj = nullptr;
  napi_create_object(env, &obj);
  napi_value vToken = nullptr;
  napi_value vSuccess = nullptr;
  napi_value vReason = nullptr;
  napi_create_int32(env, result.operationToken, &vToken);
  napi_get_boolean(env, result.success, &vSuccess);
  napi_create_int32(env, static_cast<int32_t>(result.failureReason), &vReason);
  napi_set_named_property(env, obj, "operationToken", vToken);
  napi_set_named_property(env, obj, "success", vSuccess);
  napi_set_named_property(env, obj, "failureReason", vReason);
  return obj;
}

napi_value ReleaseTextureTransaction(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) {
    return nullptr;
  }
  int32_t token = 0;
  napi_get_value_int32(env, args[0], &token);
  GlFlipEngine::GetInstance()->ReleaseTextureTransaction(token);
  return nullptr;
}

napi_value Destroy(napi_env env, napi_callback_info info) {
  (void)env;
  (void)info;
  GlFlipEngine::GetInstance()->Destroy();
  return nullptr;
}

}  // namespace

EXTERN_C_START
static napi_value InitModule(napi_env env, napi_value exports) {
  // 官方模板：exports → arkui_xcomponent → RegisterCallback（保留原实现语义）
  // 注意：libraryname 加载路径下，**每个 XComponent 实例**都会触发一次 InitModule
  // （其 exports 携带该实例的 OH_NATIVE_XCOMPONENT_OBJ）。因此回调注册**不能**用
  // static 守卫跳过——否则第二次进入阅读器时新 XComponent 实例收不到
  // OnSurfaceCreated，EGL 永不初始化，引擎恒为不可用（回归修复，2026-08-09）。
  // 每个实例注册自己的回调是安全的（不同 nativeXComponent 实例互不覆盖）。
  LOGI("InitModule: register xcomponent callbacks");
  napi_value exportInstance = nullptr;
  napi_status propStatus =
      napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance);
  static OH_NativeXComponent_Callback g_xComponentCallback = {};
  if (propStatus == napi_ok && exportInstance != nullptr) {
    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) == napi_ok &&
        nativeXComponent != nullptr) {
      g_xComponentCallback.OnSurfaceCreated = OnSurfaceCreatedCB;
      g_xComponentCallback.OnSurfaceChanged = OnSurfaceChangedCB;
      g_xComponentCallback.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
      g_xComponentCallback.DispatchTouchEvent = nullptr;
      int32_t rc = OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_xComponentCallback);
      LOGI("InitModule: RegisterCallback rc=%{public}d", rc);
    }
  }
  LOGI("InitModule: define properties");
  napi_property_descriptor desc[] = {
      {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setDisplayRefreshRate", nullptr, SetDisplayRefreshRate, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setTextures", nullptr, SetTextures, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setCompletionHandler", nullptr, SetCompletionHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"beginGesture", nullptr, BeginGesture, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"updateGesture", nullptr, UpdateGesture, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"endGesture", nullptr, EndGesture, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cancelGesture", nullptr, CancelGesture, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"beginReboundRecovery", nullptr, BeginReboundRecovery, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"releaseTextureTransaction", nullptr, ReleaseTextureTransaction, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"destroy", nullptr, Destroy, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = InitModule,
    .nm_modname = "ohrengine_gl",
    .nm_priv = ((void*)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterOhrengineGlModule(void) {
  napi_module_register(&demoModule);
}
