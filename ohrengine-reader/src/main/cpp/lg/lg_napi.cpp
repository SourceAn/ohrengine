/*
 * lg_napi.cpp — N-API 接口 + XComponent 生命周期绑定
 *
 * 只做胶水：把 ArkTS 传进来的结构化数据原样交给 lg::Renderer。
 * 效果相关的代码一行都不在这里 —— 全在 lg_renderer.cpp + lg_glsl.h。
 *
 * 数据流：
 *   componentSnapshot → PixelMap → ArrayBuffer → updateBackground()  → glTexImage2D
 *   层几何 + 形变     → Float32Array           → setLayers()         → 逐层 draw
 *   全局参数          → Float32Array           → setGlobal()
 *
 * 注意：napi 的 ArrayBuffer 是 Float32Array 的底层 buffer，这里按 float 解读，
 * 不做 JSON 解析 —— 每帧只有一次 napi 调用。
 */

#include <napi/native_api.h>

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "ace/xcomponent/native_interface_xcomponent.h"
#include "hilog/log.h"

#include "lg/lg_renderer.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "LiquidGlass"
#define LOG_DOMAIN 0x3200
#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace {

/** 每层 12 个 float，顺序见 ArkTS 侧 packing */
constexpr int32_t kLayerStride = 12;
/** 全局参数 9 个 float */
constexpr int32_t kGlobalStride = 14;

struct Instance {
    std::string id;
    std::unique_ptr<lg::Renderer> renderer;
    OH_NativeXComponent* component = nullptr;
    bool surfaceReady = false;
};

std::mutex g_mutex;
std::unordered_map<std::string, std::shared_ptr<Instance>> g_instances;
OH_NativeXComponent_Callback g_cb;

void GetId(OH_NativeXComponent* component, std::string* out) {
    char buf[OH_XCOMPONENT_ID_LEN_MAX + 1] = {0};
    uint64_t len = OH_XCOMPONENT_ID_LEN_MAX + 1;
    if (OH_NativeXComponent_GetXComponentId(component, buf, &len) ==
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        out->assign(buf, static_cast<size_t>(len));
    }
}

void Register(const std::string& id, OH_NativeXComponent* c) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_instances.find(id);
    if (it == g_instances.end()) {
        auto inst = std::make_shared<Instance>();
        inst->id = id;
        inst->component = c;
        g_instances[id] = inst;
    } else {
        it->second->component = c;
    }
}

std::shared_ptr<Instance> Find(const std::string& id) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_instances.find(id);
    return it == g_instances.end() ? nullptr : it->second;
}

/* ---------------- XComponent 生命周期 ---------------- */

void OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    std::string id;
    GetId(component, &id);
    auto inst = Find(id);
    if (inst == nullptr) {
        Register(id, component);
        inst = Find(id);
    }
    if (inst == nullptr || window == nullptr) { return; }

    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    if (w == 0 || h == 0) { return; }

    if (inst->renderer == nullptr) {
        inst->renderer = std::make_unique<lg::Renderer>();
    }
    if (!inst->renderer->Init(window, static_cast<int32_t>(w), static_cast<int32_t>(h))) {
        LOGE("[%{public}s] renderer Init 失败", id.c_str());
        inst->renderer.reset();
        return;
    }
    inst->surfaceReady = true;
    LOGI("[%{public}s] surface %{public}ux%{public}u 就绪", id.c_str(),
         static_cast<unsigned>(w), static_cast<unsigned>(h));
}

void OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    std::string id;
    GetId(component, &id);
    auto inst = Find(id);
    if (inst == nullptr || inst->renderer == nullptr || window == nullptr) { return; }
    uint64_t w = 0, h = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
    inst->renderer->Resize(static_cast<int32_t>(w), static_cast<int32_t>(h));
}

void OnSurfaceDestroyed(OH_NativeXComponent* component, void* /*window*/) {
    std::string id;
    GetId(component, &id);
    auto inst = Find(id);
    if (inst != nullptr) { inst->surfaceReady = false; }
}

/* ---------------- napi 工具 ---------------- */

bool GetStringArg(napi_env env, napi_value v, std::string* out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &len) != napi_ok) { return false; }
    out->resize(len);
    return napi_get_value_string_utf8(env, v, out->data(), len + 1, &len) == napi_ok;
}

/** 取 (id, ArrayBuffer) 两个参数 */
bool GetIdAndBuffer(napi_env env, napi_callback_info info, std::string* id, void** data,
                    size_t* bytes) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2 || !GetStringArg(env, args[0], id)) { return false; }
    bool isAb = false;
    napi_is_arraybuffer(env, args[1], &isAb);
    if (!isAb) { return false; }
    return napi_get_arraybuffer_info(env, args[1], data, bytes) == napi_ok;
}

/* ---------------- 导出接口 ---------------- */

/** setLayers(id, Float32Array.buffer) —— 每层 12 个 float */
napi_value JsSetLayers(napi_env env, napi_callback_info info) {
    std::string id;
    void* data = nullptr;
    size_t bytes = 0;
    if (!GetIdAndBuffer(env, info, &id, &data, &bytes)) { return nullptr; }
    auto inst = Find(id);
    if (inst == nullptr || inst->renderer == nullptr) { return nullptr; }

    const int32_t n = static_cast<int32_t>(bytes / (sizeof(float) * kLayerStride));
    std::vector<lg::Layer> layers(static_cast<size_t>(n < 0 ? 0 : n));
    const float* f = static_cast<const float*>(data);
    for (int32_t i = 0; i < n; ++i) {
        const float* p = f + i * kLayerStride;
        lg::Layer& L = layers[static_cast<size_t>(i)];
        L.x = p[0]; L.y = p[1]; L.w = p[2]; L.h = p[3]; L.r = p[4];
        L.kind = static_cast<int32_t>(p[5]);
        L.opacity = p[6];
        L.amp = p[7];
        L.pressX = p[8]; L.pressY = p[9];
        L.carried = p[10];
        L.pressR = p[11];
    }
    inst->renderer->SetLayers(layers.data(), n);
    LOGI("[%{public}s] setLayers n=%{public}d bytes=%{public}zu", id.c_str(), n, bytes);
    return nullptr;
}

/** setGlobal(id, Float32Array.buffer) —— 9 个 float */
napi_value JsSetGlobal(napi_env env, napi_callback_info info) {
    std::string id;
    void* data = nullptr;
    size_t bytes = 0;
    if (!GetIdAndBuffer(env, info, &id, &data, &bytes)) { return nullptr; }
    auto inst = Find(id);
    if (inst == nullptr || inst->renderer == nullptr) { return nullptr; }
    if (bytes < sizeof(float) * kGlobalStride) { return nullptr; }
    const float* p = static_cast<const float*>(data);
    inst->renderer->SetGlobal(p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9],
                              p[10], p[11], p[12], p[13]);
    return nullptr;
}

/** updateBackground(id, buf, w, h, rowStridePx) */
napi_value JsUpdateBackground(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 5 || !GetStringArg(env, args[0], &id)) { return nullptr; }
    bool isAb = false;
    napi_is_arraybuffer(env, args[1], &isAb);
    if (!isAb) { return nullptr; }
    void* data = nullptr;
    size_t bytes = 0;
    napi_get_arraybuffer_info(env, args[1], &data, &bytes);
    int32_t w = 0, h = 0, stride = 0;
    napi_get_value_int32(env, args[2], &w);
    napi_get_value_int32(env, args[3], &h);
    napi_get_value_int32(env, args[4], &stride);
    auto inst = Find(id);
    if (inst == nullptr || inst->renderer == nullptr) { return nullptr; }
    inst->renderer->UpdateBackground(static_cast<const uint8_t*>(data), w, h, stride);
    return nullptr;
}

/** render(id) —— 出帧一次 */
napi_value JsRender(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], &id)) { return nullptr; }
    auto inst = Find(id);
    napi_value out = nullptr;
    bool drew = false;
    if (inst == nullptr) {
        LOGE("[%{public}s] render: instance 不存在", id.c_str());
    } else if (inst->renderer == nullptr) {
        LOGE("[%{public}s] render: renderer 为空", id.c_str());
    } else if (!inst->surfaceReady) {
        LOGE("[%{public}s] render: surface 未就绪", id.c_str());
    } else {
        drew = inst->renderer->RenderFrame();
    }
    napi_get_boolean(env, drew, &out);
    return out;
}

/** getStats(id) → [frameMs, drawCalls, layerCount, blurCacheHit, blurCacheMiss, programErrors] */
napi_value JsGetStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc >= 1) { GetStringArg(env, args[0], &id); }
    lg::RendererStats s;
    auto inst = Find(id);
    if (inst != nullptr && inst->renderer != nullptr) { s = inst->renderer->Stats(); }

    const float values[6] = {
        s.frameMs,
        static_cast<float>(s.drawCalls),
        static_cast<float>(s.layerCount),
        static_cast<float>(s.blurCacheHit),
        static_cast<float>(s.blurCacheMiss),
        static_cast<float>(s.programErrors),
    };
    void* out = nullptr;
    napi_value buf = nullptr;
    napi_create_arraybuffer(env, sizeof(values), &out, &buf);
    for (size_t i = 0; i < 6; ++i) { static_cast<float*>(out)[i] = values[i]; }
    napi_value arr = nullptr;
    napi_create_typedarray(env, napi_float32_array, 6, buf, 0, &arr);
    return arr;
}

/** isReady(id) */
napi_value JsIsReady(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], &id)) { return nullptr; }
    auto inst = Find(id);
    napi_value out = nullptr;
    napi_get_boolean(env, inst != nullptr && inst->surfaceReady && inst->renderer != nullptr, &out);
    return out;
}

/** dispose(id) */
napi_value JsDispose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string id;
    if (argc < 1 || !GetStringArg(env, args[0], &id)) { return nullptr; }
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_instances.find(id);
    if (it != g_instances.end()) {
        if (it->second->renderer != nullptr) { it->second->renderer->Dispose(); }
        g_instances.erase(it);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"setLayers", nullptr, JsSetLayers, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGlobal", nullptr, JsSetGlobal, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateBackground", nullptr, JsUpdateBackground, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"render", nullptr, JsRender, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats", nullptr, JsGetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isReady", nullptr, JsIsReady, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"dispose", nullptr, JsDispose, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) !=
        napi_ok) {
        LOGE("XComponent object not found on exports");
        return exports;
    }
    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) != napi_ok ||
        nativeXComponent == nullptr) {
        LOGE("unwrap XComponent failed");
        return exports;
    }
    g_cb.OnSurfaceCreated = OnSurfaceCreated;
    g_cb.OnSurfaceChanged = OnSurfaceChanged;
    g_cb.OnSurfaceDestroyed = OnSurfaceDestroyed;
    g_cb.DispatchTouchEvent = nullptr;
    if (OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_cb) !=
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        LOGE("RegisterCallback failed");
    }
    LOGI("liquidglass(lg) module registered");
    return exports;
}

}  // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "liquidglass",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterLiquidGlassModule() {
    napi_module_register(&g_module);
}
