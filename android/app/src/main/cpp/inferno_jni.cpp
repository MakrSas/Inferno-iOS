/*
 * JNI bridge to the Inferno emulator library.
 *
 * This file is deliberately thin and deliberately independent of
 * inferno-src: it never includes the emulator's own headers and never links
 * against it. Everything — qemu_init, qemu_main_loop, qemu_cleanup, and the
 * inferno_display_.../inferno_input_.../inferno_net_link_up surface
 * documented in include/ui/inferno-embed.h — is resolved with dlopen/dlsym
 * at runtime, exactly like QemuBridge.swift does on iOS. Two reasons:
 *
 *   1. The .so this app actually needs (libqemu-aarch64-softmmu.so,
 *      cross-compiled for Android per ../../../ANDROID-PORT.md) doesn't
 *      exist in this tree yet, and this module has to build without it.
 *   2. Once it does exist, nothing here has to change — it's dropped into
 *      app-specific storage or jniLibs and loaded by path, not linked.
 *
 * The struct InfernoFrameInfo packs (width, height, stride, x, y, w, h,
 * generation) as eight consecutive uint32_t with no padding, so it is passed
 * across this boundary as a plain uint32_t[8] rather than by redeclaring the
 * struct — one less thing that can drift out of sync with the header.
 *
 * Copyright (c) 2026 Inferno Android port.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include <jni.h>
#include <android/log.h>
#include <dlfcn.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <pthread.h>
#include <string>
#include <vector>

#define LOG_TAG "InfernoJNI"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

using InitFn = void (*)(int, char**);
using MainLoopFn = int (*)();
using CleanupFn = void (*)(int);
using VoidFn = void (*)();
using DisplayReadFn = int32_t (*)(void*, size_t, uint32_t*);
using TouchFn = void (*)(int32_t, int32_t, bool);
using KeyFn = void (*)(uint32_t, bool);
using NetLinkUpFn = bool (*)();

void* g_handle = nullptr;
InitFn g_init = nullptr;
MainLoopFn g_main_loop = nullptr;
CleanupFn g_cleanup = nullptr;
VoidFn g_display_attach = nullptr;
VoidFn g_display_detach = nullptr;
VoidFn g_display_invalidate = nullptr;
DisplayReadFn g_display_read = nullptr;
TouchFn g_touch = nullptr;
KeyFn g_key = nullptr;
NetLinkUpFn g_net_link_up = nullptr;

JavaVM* g_vm = nullptr;
jobject g_bridge_instance = nullptr; // global ref to the Kotlin QemuBridge object
jmethodID g_on_state_change_mid = nullptr;
std::mutex g_callback_mutex;

// States as Kotlin's QemuBridge.State enum orders them: IDLE, RUNNING,
// STOPPED, FAILED. Kept as plain ints across the boundary rather than
// exporting the enum, same spirit as the InfernoFrameInfo layout above.
enum class BridgeState : jint { IDLE = 0, RUNNING = 1, STOPPED = 2, FAILED = 3 };

/// Remembers how to call back into QemuBridge.onNativeStateChange from any
/// thread, including the detached one qemu itself runs on. Safe to call
/// repeatedly; only the first call does anything.
void cacheCallbackRefs(JNIEnv* env, jobject thiz) {
    std::lock_guard<std::mutex> guard(g_callback_mutex);
    if (g_bridge_instance != nullptr) { return; }
    jclass cls = env->GetObjectClass(thiz);
    g_bridge_instance = env->NewGlobalRef(thiz);
    // Plain (public) visibility on the Kotlin side, not private/internal —
    // see the comment on onNativeStateChange in QemuBridge.kt for why.
    g_on_state_change_mid = env->GetMethodID(cls, "onNativeStateChange", "(IILjava/lang/String;)V");
    env->DeleteLocalRef(cls);
    if (g_on_state_change_mid == nullptr) {
        LOGE("onNativeStateChange not found — state changes will be silently dropped");
    }
}

void postState(JNIEnv* env, BridgeState state, jint exitCode, const char* message) {
    if (g_bridge_instance == nullptr || g_on_state_change_mid == nullptr) { return; }
    jstring jmessage = message != nullptr ? env->NewStringUTF(message) : nullptr;
    env->CallVoidMethod(g_bridge_instance, g_on_state_change_mid,
                        static_cast<jint>(state), exitCode, jmessage);
    if (jmessage != nullptr) { env->DeleteLocalRef(jmessage); }
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
}

/// Swaps R and B in place over one rectangle. The emulator hands back
/// little-endian a8r8g8b8 (memory order B,G,R,A); Android's ARGB_8888
/// bitmaps are R,G,B,A. Scoped to the dirty rectangle only, same as the
/// memcpy inferno_display_read itself just did — no reason to touch pixels
/// that didn't change.
void swapRedBlue(void* dst, uint32_t stride, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (dst == nullptr || w == 0 || h == 0) { return; }
    auto* base = static_cast<uint8_t*>(dst);
    for (uint32_t row = y; row < y + h; ++row) {
        uint8_t* pixel = base + static_cast<size_t>(row) * stride + static_cast<size_t>(x) * 4;
        for (uint32_t col = 0; col < w; ++col) {
            std::swap(pixel[0], pixel[2]);
            pixel += 4;
        }
    }
}

struct StartArgs {
    std::vector<std::string> argv;
};

void* runQemu(void* raw) {
    std::unique_ptr<StartArgs> args(static_cast<StartArgs*>(raw));

    JNIEnv* env = nullptr;
    // JNI_VERSION_1_6 matches JNI_OnLoad below; a detached native thread has
    // no JNIEnv of its own until it attaches.
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
        LOGE("AttachCurrentThread failed; the machine will run but its state changes go nowhere");
        env = nullptr;
    }

    std::vector<char*> cargv;
    cargv.reserve(args->argv.size() + 1);
    for (auto& s : args->argv) { cargv.push_back(s.data()); }
    cargv.push_back(nullptr);
    int argc = static_cast<int>(args->argv.size());

    if (env != nullptr) { postState(env, BridgeState::RUNNING, 0, nullptr); }

    // qemu_init returns holding QEMU's own big lock, and qemu_main_loop
    // expects to be entered that way — the same contract QemuBridge.swift
    // relies on, and the reason both calls happen on this one thread.
    g_init(argc, cargv.data());
    int status = g_main_loop();
    g_cleanup(status);

    if (env != nullptr) {
        postState(env, BridgeState::STOPPED, status, nullptr);
        g_vm->DetachCurrentThread();
    }
    return nullptr;
}

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeLoad(JNIEnv* env, jobject thiz, jstring jpath) {
    cacheCallbackRefs(env, thiz);

    const char* path = env->GetStringUTFChars(jpath, nullptr);
    void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        LOGE("dlopen(%s) failed: %s", path, dlerror());
        env->ReleaseStringUTFChars(jpath, path);
        return JNI_FALSE;
    }
    LOGI("loaded %s", path);
    env->ReleaseStringUTFChars(jpath, path);
    g_handle = handle;

    g_init = reinterpret_cast<InitFn>(dlsym(handle, "qemu_init"));
    g_main_loop = reinterpret_cast<MainLoopFn>(dlsym(handle, "qemu_main_loop"));
    g_cleanup = reinterpret_cast<CleanupFn>(dlsym(handle, "qemu_cleanup"));
    // The display/input/net surface is resolved best-effort: an older build
    // of the library missing one of them shouldn't stop it from starting
    // headless, and nativeHasSymbol / a null function pointer downstream
    // says clearly what is and isn't there.
    g_display_attach = reinterpret_cast<VoidFn>(dlsym(handle, "inferno_display_attach"));
    g_display_detach = reinterpret_cast<VoidFn>(dlsym(handle, "inferno_display_detach"));
    g_display_invalidate = reinterpret_cast<VoidFn>(dlsym(handle, "inferno_display_invalidate"));
    g_display_read = reinterpret_cast<DisplayReadFn>(dlsym(handle, "inferno_display_read"));
    g_touch = reinterpret_cast<TouchFn>(dlsym(handle, "inferno_input_touch"));
    g_key = reinterpret_cast<KeyFn>(dlsym(handle, "inferno_input_function_key"));
    g_net_link_up = reinterpret_cast<NetLinkUpFn>(dlsym(handle, "inferno_net_link_up"));

    bool ok = g_init != nullptr && g_main_loop != nullptr && g_cleanup != nullptr;
    if (!ok) { LOGE("missing qemu_init/qemu_main_loop/qemu_cleanup in %s", path); }
    return ok ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeIsLoaded(JNIEnv*, jobject) {
    return (g_init != nullptr && g_main_loop != nullptr && g_cleanup != nullptr) ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeHasSymbol(JNIEnv* env, jobject, jstring jname) {
    if (g_handle == nullptr) { return JNI_FALSE; }
    const char* name = env->GetStringUTFChars(jname, nullptr);
    void* symbol = dlsym(g_handle, name);
    env->ReleaseStringUTFChars(jname, name);
    return symbol != nullptr ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeStart(JNIEnv* env, jobject thiz, jobjectArray jargv) {
    if (g_init == nullptr || g_main_loop == nullptr || g_cleanup == nullptr) { return JNI_FALSE; }
    cacheCallbackRefs(env, thiz);

    auto args = new StartArgs();
    jsize argc = env->GetArrayLength(jargv);
    args->argv.reserve(argc);
    for (jsize i = 0; i < argc; ++i) {
        auto jstr = static_cast<jstring>(env->GetObjectArrayElement(jargv, i));
        const char* chars = env->GetStringUTFChars(jstr, nullptr);
        args->argv.emplace_back(chars);
        env->ReleaseStringUTFChars(jstr, chars);
        env->DeleteLocalRef(jstr);
    }

    pthread_t thread;
    // The translation buffer and device emulation want room to breathe —
    // same reasoning as the 4 MiB stack QemuBridge.swift gives its thread.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
    int rc = pthread_create(&thread, &attr, &runQemu, args);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        LOGE("pthread_create failed: %d", rc);
        delete args;
        return JNI_FALSE;
    }
    pthread_detach(thread);
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeDisplayAttach(JNIEnv*, jobject) {
    if (g_display_attach != nullptr) { g_display_attach(); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeDisplayDetach(JNIEnv*, jobject) {
    if (g_display_detach != nullptr) { g_display_detach(); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeDisplayInvalidate(JNIEnv*, jobject) {
    if (g_display_invalidate != nullptr) { g_display_invalidate(); }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeDisplayRead(JNIEnv* env, jobject, jobject jdst, jintArray jinfo) {
    uint32_t info[8] = {0};
    if (g_display_read == nullptr) {
        env->SetIntArrayRegion(jinfo, 0, 8, reinterpret_cast<jint*>(info));
        return 0; // INFERNO_FRAME_NONE
    }

    void* dst = nullptr;
    jlong capacity = 0;
    if (jdst != nullptr) {
        dst = env->GetDirectBufferAddress(jdst);
        capacity = env->GetDirectBufferCapacity(jdst);
    }

    int32_t result = g_display_read(dst, static_cast<size_t>(capacity), info);
    if (result == 1 && dst != nullptr) { // INFERNO_FRAME_OK
        swapRedBlue(dst, info[2], info[3], info[4], info[5], info[6]);
    }

    // uint32_t and jint are both 32 bits; the values in play (framebuffer
    // dimensions and a generation counter) never approach 2^31.
    env->SetIntArrayRegion(jinfo, 0, 8, reinterpret_cast<jint*>(info));
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeInputTouch(JNIEnv*, jobject, jint x, jint y, jboolean pressed) {
    if (g_touch != nullptr) { g_touch(x, y, pressed == JNI_TRUE); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeInputFunctionKey(JNIEnv*, jobject, jint number, jboolean pressed) {
    if (g_key != nullptr) { g_key(static_cast<uint32_t>(number), pressed == JNI_TRUE); }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_makr_inferno_bridge_QemuBridge_nativeNetLinkUp(JNIEnv*, jobject) {
    return (g_net_link_up != nullptr && g_net_link_up()) ? JNI_TRUE : JNI_FALSE;
}
