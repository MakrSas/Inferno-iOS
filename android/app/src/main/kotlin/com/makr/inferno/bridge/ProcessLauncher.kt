package com.makr.inferno.bridge

/**
 * fork()+execve() from native code — see process_launcher.cpp. The one
 * thing this exists for: android.os.ProcessBuilder wires up only
 * stdin/stdout/stderr and closes every other file descriptor in the child
 * for safety, so it can't hand the emulator process the already-open SAF
 * file descriptor its root disk needs (see VMConfig.resolveRootImage and
 * QemuProcess).
 */
object ProcessLauncher {
    init { System.loadLibrary("inferno_jni") }

    /**
     * Forks and execs [path] with [argv] (argv[0] included) and [envp]
     * (each entry `"KEY=value"`, replacing the environment entirely —
     * android.os.ProcessBuilder's own default of inheriting the caller's
     * environment isn't done here, so pass everything the child needs).
     * Every fd named in [keepOpenFds] has its close-on-exec flag cleared in
     * the child before execve() — without that, a fd this process opened
     * (even one never explicitly marked CLOEXEC) may not survive the exec.
     * Returns the child's pid, or -1 if fork() itself failed; a failure in
     * execve() itself (bad path, say) only shows up as the child exiting
     * immediately with status 127, since nothing after fork() in the child
     * may safely report an error back through JNI.
     *
     * [stdoutFd]/[stderrFd], when >= 0, are dup2'd onto the child's own
     * STDOUT_FILENO/STDERR_FILENO before execve() — logcat does not capture
     * a forked child's output the way it does this process's own, so
     * without this there is no way to see anything the emulator prints
     * before it dies. Pass -1 to leave a stream as inherited from this
     * process (i.e. going nowhere useful).
     */
    external fun nativeForkExec(
        path: String,
        argv: Array<String>,
        envp: Array<String>,
        keepOpenFds: IntArray,
        stdoutFd: Int,
        stderrFd: Int,
    ): Int
}
