# Add project specific ProGuard rules here.
# Release builds ship unminified for now (see build.gradle.kts) while the
# native bridge is still taking shape; rules can be tightened once it's real.

# inferno_jni.cpp finds this class and its callback method by exact
# package/class/method name (Java_com_makr_inferno_bridge_QemuBridge_...,
# and a cached GetMethodID for onNativeStateChange) — R8 must never rename,
# inline, or remove any of it, minification on or off.
-keep class com.makr.inferno.bridge.QemuBridge { *; }
