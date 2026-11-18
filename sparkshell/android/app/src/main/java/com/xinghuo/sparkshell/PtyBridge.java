package com.xinghuo.sparkshell;

/** JNI 声明：实现见 src/main/cpp/pty_bridge.c。 */
final class PtyBridge {
    static {
        System.loadLibrary("ptybridge");
    }

    private PtyBridge() {
    }

    static native int open(String shell);

    static native byte[] read(int fd, int max);

    static native int write(int fd, byte[] data);

    static native void close(int fd);
}
