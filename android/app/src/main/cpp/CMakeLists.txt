cmake_minimum_required(VERSION 3.22.1)
project(inferno_jni)

# Thin JNI glue only — see inferno_jni.cpp for why this doesn't link the
# emulator itself. Kept deliberately small: everything it needs from the
# emulator's shared library is resolved with dlopen/dlsym at runtime, so
# nothing here depends on inferno-src being checked out at build time.
add_library(inferno_jni SHARED
    inferno_jni.cpp
)

target_link_libraries(inferno_jni
    log
    android
)

# Required for the library to load at all on 16 KB-page devices
# (Android 15+ on some hardware); see ANDROID-PORT.md ("Размер страницы").
target_link_options(inferno_jni PRIVATE "-Wl,-z,max-page-size=16384")
