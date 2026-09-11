cmake_minimum_required(VERSION 3.22.1)
project(inferno_jni)

# Just fork()+execve() with a way to keep one extra fd open across it — see
# process_launcher.cpp. The emulator itself runs as a separate process (see
# ANDROID-PORT.md) and talks to the app over a socket, not JNI, so nothing
# here links against it or depends on inferno-src being checked out.
add_library(inferno_jni SHARED
    process_launcher.cpp
)

target_link_libraries(inferno_jni
    log
)

# Required for the library to load at all on 16 KB-page devices
# (Android 15+ on some hardware); see ANDROID-PORT.md ("Размер страницы").
target_link_options(inferno_jni PRIVATE "-Wl,-z,max-page-size=16384")
