#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

// 打开一个 PTY，fork 出 shell，返回 master fd。
// 纯 NDK 实现：posix_openpt + grantpt + unlockpt + setsid + dup2 + execv
static int make_pty(const char *shell) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return -1;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        close(master);
        return -1;
    }
    char *slave_name = ptsname(master);
    if (!slave_name) {
        close(master);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        return -1;
    }
    if (pid == 0) {
        setsid();
        int slave = open(slave_name, O_RDWR);
        if (slave < 0) _exit(127);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        ioctl(STDIN_FILENO, TIOCSCTTY, 0);
        execl(shell, "sh", (char *)NULL);
        _exit(127);
    }

    int flags = fcntl(master, F_GETFL, 0);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
    return master;
}

JNIEXPORT jint JNICALL
Java_com_xinghuo_sparkshell_PtyBridge_open(JNIEnv *env, jclass clazz, jstring shell) {
    const char *path = (*env)->GetStringUTFChars(env, shell, NULL);
    int fd = make_pty(path ? path : "/system/bin/sh");
    if (path) (*env)->ReleaseStringUTFChars(env, shell, path);
    return fd;
}

JNIEXPORT jbyteArray JNICALL
Java_com_xinghuo_sparkshell_PtyBridge_read(JNIEnv *env, jclass clazz, jint fd, jint max) {
    if (max <= 0 || max > 65536) max = 8192;
    char *buf = (char *)malloc((size_t)max);
    if (!buf) return NULL;
    ssize_t n = read(fd, buf, (size_t)max);
    if (n <= 0) {
        free(buf);
        return NULL;
    }
    jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
    if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (const jbyte *)buf);
    free(buf);
    return out;
}

JNIEXPORT jint JNICALL
Java_com_xinghuo_sparkshell_PtyBridge_write(JNIEnv *env, jclass clazz, jint fd, jbyteArray data) {
    jsize len = (*env)->GetArrayLength(env, data);
    jbyte *buf = (*env)->GetByteArrayElements(env, data, NULL);
    ssize_t n = write(fd, buf, (size_t)len);
    (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
    return (jint)n;
}

JNIEXPORT void JNICALL
Java_com_xinghuo_sparkshell_PtyBridge_close(JNIEnv *env, jclass clazz, jint fd) {
    if (fd >= 0) close(fd);
}
