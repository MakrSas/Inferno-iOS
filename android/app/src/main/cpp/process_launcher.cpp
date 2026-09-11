/*
 * fork()+execve() for launching the emulator as this app's own child
 * process — see ANDROID-PORT.md on why it runs as a separate process at
 * all, and QemuProcess.kt for the Kotlin side of this.
 *
 * The one thing plain android.os.ProcessBuilder can't do that this needs:
 * hand the child a specific already-open file descriptor (the guest's root
 * disk, opened through the Storage Access Framework, at the exact fd
 * number QemuProcess.kt already baked into a "-drive file=/proc/self/fd/N"
 * argument) — ProcessBuilder only wires up stdin/stdout/stderr, and closes
 * everything else out from under the child for safety.
 *
 * fork() in a process this size (an Android app, meaning ART and every
 * thread it runs) is safe exactly because the child does nothing on this
 * side but async-signal-safe calls before execve() replaces it entirely —
 * fcntl/execve/_exit only, no malloc, no JNIEnv, nothing libc might have
 * left mid-operation on some other thread at the moment of the fork. All
 * the real work (building C strings, arrays) happens before forking.
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

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <unistd.h>
#include <vector>

#define LOG_TAG "ProcessLauncher"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

std::vector<std::string> toStringVector(JNIEnv* env, jobjectArray array) {
    std::vector<std::string> out;
    if (array == nullptr) { return out; }
    jsize n = env->GetArrayLength(array);
    out.reserve(n);
    for (jsize i = 0; i < n; ++i) {
        auto jstr = static_cast<jstring>(env->GetObjectArrayElement(array, i));
        const char* chars = env->GetStringUTFChars(jstr, nullptr);
        out.emplace_back(chars);
        env->ReleaseStringUTFChars(jstr, chars);
        env->DeleteLocalRef(jstr);
    }
    return out;
}

std::vector<char*> toCArgv(std::vector<std::string>& strings) {
    std::vector<char*> out;
    out.reserve(strings.size() + 1);
    for (auto& s : strings) { out.push_back(s.data()); }
    out.push_back(nullptr);
    return out;
}

} // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_makr_inferno_bridge_ProcessLauncher_nativeForkExec(
    JNIEnv* env, jobject /*thiz*/, jstring jpath, jobjectArray jargv, jobjectArray jenvp, jintArray jkeepFds,
    jint stdoutFd, jint stderrFd) {
    const char* pathChars = env->GetStringUTFChars(jpath, nullptr);
    std::string path(pathChars);
    env->ReleaseStringUTFChars(jpath, pathChars);

    // Everything allocation-requiring happens here, in the parent, before
    // fork() — the child below may not allocate.
    std::vector<std::string> argvStrings = toStringVector(env, jargv);
    std::vector<std::string> envpStrings = toStringVector(env, jenvp);
    std::vector<char*> argv = toCArgv(argvStrings);
    std::vector<char*> envp = toCArgv(envpStrings);

    jsize keepCount = jkeepFds != nullptr ? env->GetArrayLength(jkeepFds) : 0;
    std::vector<jint> keepFds(static_cast<size_t>(keepCount));
    if (keepCount > 0) { env->GetIntArrayRegion(jkeepFds, 0, keepCount, keepFds.data()); }

    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork() failed: %s", strerror(errno));
        return -1;
    }
    if (pid == 0) {
        // Child: async-signal-safe operations only, all the way to execve.
        // dup2 first — stdoutFd/stderrFd themselves might collide with a
        // low-numbered fd this loop is about to touch otherwise.
        if (stdoutFd >= 0) { dup2(stdoutFd, STDOUT_FILENO); }
        if (stderrFd >= 0) { dup2(stderrFd, STDERR_FILENO); }
        for (jint fd : keepFds) { fcntl(fd, F_SETFD, 0); /* clear FD_CLOEXEC */ }
        execve(path.c_str(), argv.data(), envp.data());
        // Only reached if execve itself failed.
        _exit(127);
    }
    return static_cast<jint>(pid);
}
