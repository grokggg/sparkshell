package com.xinghuo.sparkshell;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.webkit.MimeTypeMap;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;

import java.util.ArrayList;
import java.util.List;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 极简宿主。
 *  - PTY 通道：open/read/write/close（native 实现在 pty_bridge.c）
 *  - IO 通道：pickAndImport / pickAndImportTo / pickImages / pickFiles / exportFile（Activity Result）
 *    + installApk（拉起系统安装器）。pickImages、pickFiles 是聊天附件用的，固定复制进 /root/inbox。
 *  - 环境准备：prepareRootfs —— 把 APK 内的 rootfs.tar 流式落盘，再用 toybox tar 解包
 *
 * prepareRootfs 返回 String：成功为 "ok"，失败为可直接打印的诊断串（含 tar 退出码/输出/剩余空间）。
 * 之所以不再以 tar 退出码判定成败：解包 250 MB Debian rootfs 时 chown/mknod 类操作必然报错，
 * 退出码非 0 但文件是完整的；改为校验关键路径是否存在。
 */
public class MainActivity extends FlutterActivity {

    private static final String CHANNEL = "com.xinghuo.sparkshell/pty";
    private static final String IO_CHANNEL = "sparkshell/io";
    /**
     * IO 通道的别名。历史 Dart 代码用的是 "sparkshell/io"，聊天页的附件选择器按包名写成了
     * "com.xinghuo.sparkshell/io"。两个名字挂同一个 handler，谁也不用改。
     */
    private static final String IO_CHANNEL_ALIAS = "com.xinghuo.sparkshell/io";
    private static final int REQ_PICK = 4711;
    private static final long MAX_IMPORT = 200L * 1024 * 1024;

    /** 聊天附件统一落到容器的 /root/inbox，便于用户和容器内程序按固定路径找。 */
    private static final String INBOX_DIR = "/root/inbox";

    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel.Result pendingPick;   // 选择器是异步的，得先存住 Result
    private String pendingDest = "/root/import";

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler(new MethodChannel.MethodCallHandler() {
                    @Override
                    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
                        try {
                            switch (call.method) {
                                case "filesDir": {
                                    result.success(getApplicationContext().getFilesDir().getAbsolutePath());
                                    break;
                                }
                                case "prepareRootfs": {
                                    final MethodChannel.Result r = result;
                                    new Thread(() -> {
                                        String out;
                                        try {
                                            out = extractRootfs();
                                        } catch (Throwable t) {
                                            out = "异常: " + t;
                                        }
                                        final String msg = out;
                                        main.post(() -> r.success(msg));
                                    }).start();
                                    break;
                                }
                                case "open": {
                                    String shell = call.argument("shell");
                                    result.success(PtyBridge.open(shell == null ? "/system/bin/sh" : shell));
                                    break;
                                }
                                case "read": {
                                    Integer fd = call.argument("fd");
                                    Integer max = call.argument("max");
                                    if (fd == null || fd < 0) {
                                        result.success(null);
                                    } else {
                                        result.success(PtyBridge.read(fd, max == null ? 8192 : max));
                                    }
                                    break;
                                }
                                case "write": {
                                    Integer fd = call.argument("fd");
                                    byte[] data = call.argument("data");
                                    if (fd == null || fd < 0 || data == null) {
                                        result.success(-1);
                                    } else {
                                        result.success(PtyBridge.write(fd, data));
                                    }
                                    break;
                                }
                                case "close": {
                                    Integer fd = call.argument("fd");
                                    if (fd != null) PtyBridge.close(fd);
                                    result.success(true);
                                    break;
                                }
                                default:
                                    result.notImplemented();
                                    break;
                            }
                        } catch (Throwable t) {
                            result.error("pty_error", String.valueOf(t.getMessage()), null);
                        }
                    }
                });

        MethodChannel.MethodCallHandler ioHandler = new MethodChannel.MethodCallHandler() {
            @Override
            public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
                try {
                    switch (call.method) {
                        case "pickAndImport": {
                            openPicker(result, "/root/import", "*/*");
                            break;
                        }
                        case "pickAndImportTo": {
                            String dest = call.argument("destDir");
                            openPicker(result, dest == null || dest.isEmpty() ? "/root/import" : dest, "*/*");
                            break;
                        }
                        // 聊天附件：只要图片，允许多选，落点固定为容器 /root/inbox。
                        case "pickImages": {
                            openPicker(result, INBOX_DIR, "image/*");
                            break;
                        }
                        // 聊天附件：任意文件（文档、压缩包、音频都行），同样多选、落点 /root/inbox。
                        case "pickFiles": {
                            openPicker(result, INBOX_DIR, "*/*");
                            break;
                        }
                        case "exportFile": {
                            String guest = call.argument("path");
                            if (guest == null) {
                                result.error("bad_args", "缺少 path", null);
                            } else {
                                shareFile(result, guest);
                            }
                            break;
                        }
                        case "installApk": {
                            String path = call.argument("path");
                            if (path == null || path.trim().isEmpty()) {
                                result.error("bad_args", "缺少 path", null);
                            } else {
                                installApk(result, path.trim());
                            }
                            break;
                        }
                        default:
                            result.notImplemented();
                            break;
                    }
                } catch (Throwable t) {
                    result.error("io_error", String.valueOf(t.getMessage()), null);
                }
            }
        };
        // 同一个 handler 挂两个通道名：老的 sparkshell/io 继续可用，新的包名通道给附件选择器用。
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), IO_CHANNEL)
                .setMethodCallHandler(ioHandler);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), IO_CHANNEL_ALIAS)
                .setMethodCallHandler(ioHandler);
    }

    /** 拉起系统文件选择器：mimeType 决定看到的类型（image/* 只看图片），destDir 是容器内落点。 */
    private void openPicker(MethodChannel.Result result, String destDir, String mimeType) {
        if (pendingPick != null) {
            result.error("busy", "文件选择器已经打开", null);
            return;
        }
        pendingPick = result;
        pendingDest = destDir;
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        i.addCategory(Intent.CATEGORY_OPENABLE);
        i.setType(mimeType == null || mimeType.isEmpty() ? "*/*" : mimeType);
        i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try {
            startActivityForResult(i, REQ_PICK);
        } catch (Throwable t) {
            pendingPick = null;
            result.error("no_picker", "没有可用的文件选择器: " + t.getMessage(), null);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_PICK) return;
        final MethodChannel.Result r = pendingPick;
        pendingPick = null;
        if (r == null) return;
        if (resultCode != Activity.RESULT_OK || data == null) {
            r.success(new ArrayList<String>());
            return;
        }
        final List<Uri> uris = new ArrayList<>();
        if (data.getClipData() != null) {
            for (int k = 0; k < data.getClipData().getItemCount(); k++) {
                uris.add(data.getClipData().getItemAt(k).getUri());
            }
        } else if (data.getData() != null) {
            uris.add(data.getData());
        }
        final String dest = pendingDest;
        if (uris.isEmpty()) {
            // 用户点了「取消」但系统仍回 RESULT_OK 的情况：按取消处理，返回空列表。
            r.success(new ArrayList<String>());
            return;
        }
        new Thread(() -> {
            List<String> ok = new ArrayList<>();
            String err = null;
            for (Uri u : uris) {
                try {
                    String guest = importOne(u, dest);
                    if (guest != null) ok.add(guest);
                } catch (Throwable t) {
                    // 只留一句人能看懂的原因；多个文件失败时以最后一个为准（已经成功的仍会返回）。
                    String m = t.getMessage();
                    err = (m == null || m.trim().isEmpty()) ? "读取源文件失败" : m.trim();
                }
            }
            final List<String> out = ok;
            final String e = err;
            main.post(() -> {
                if (e != null && out.isEmpty()) {
                    r.error("import_failed", "复制文件到容器失败：" + e, null);
                } else {
                    r.success(out);
                }
            });
        }).start();
    }

    /** 把一个 content:// 复制进 rootfs，返回容器路径。 */
    private String importOne(Uri uri, String destDir) throws Exception {
        File rootfs = new File(getApplicationContext().getFilesDir(), "rootfs");
        String name = displayName(uri);
        File dir = new File(rootfs, destDir.startsWith("/") ? destDir.substring(1) : destDir);
        if (!dir.mkdirs() && !dir.isDirectory()) throw new Exception("无法创建目录 " + dir);
        File target = unique(dir, name);
        try (InputStream in = getContentResolver().openInputStream(uri);
             OutputStream out = new FileOutputStream(target)) {
            if (in == null) throw new Exception("读不到 " + uri);
            byte[] buf = new byte[1 << 16];
            long total = 0;
            int n;
            while ((n = in.read(buf)) > 0) {
                total += n;
                if (total > MAX_IMPORT) {
                    target.delete();
                    throw new Exception("文件超过 200MB");
                }
                out.write(buf, 0, n);
            }
        }
        String guestDir = destDir.startsWith("/") ? destDir : "/" + destDir;
        return (guestDir.endsWith("/") ? guestDir : guestDir + "/") + target.getName();
    }

    private String displayName(Uri uri) {
        String name = null;
        try (Cursor c = getContentResolver().query(uri, null, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) name = c.getString(idx);
            }
        } catch (Throwable ignored) {
        }
        if (name == null) name = uri.getLastPathSegment();
        return sanitize(name == null ? "unnamed" : name);
    }

    /** 去掉路径分隔符与非法字符，杜绝 "../x" 这类名字。 */
    private static String sanitize(String name) {
        String s = name.replaceAll("[\\\\/:*?\"<>|]", "_").replace("..", "_").trim();
        if (s.isEmpty() || s.equals("_")) s = "unnamed";
        return s.length() > 120 ? s.substring(s.length() - 120) : s;
    }

    private static File unique(File dir, String name) {
        File f = new File(dir, name);
        if (!f.exists()) return f;
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int i = 1; i < 1000; i++) {
            f = new File(dir, base + "-" + i + ext);
            if (!f.exists()) return f;
        }
        return new File(dir, base + "-" + System.currentTimeMillis() + ext);
    }

    private void shareFile(MethodChannel.Result result, String guest) {
        try {
            File rootfs = new File(getApplicationContext().getFilesDir(), "rootfs");
            File src = new File(rootfs, guest.startsWith("/") ? guest.substring(1) : guest);
            if (!src.exists() || src.isDirectory()) {
                result.error("not_found", "文件不存在: " + guest, null);
                return;
            }
            File dir = new File(getApplicationContext().getCacheDir(), "exports");
            if (!dir.mkdirs() && !dir.isDirectory()) throw new Exception("无法创建导出目录");
            File dst = new File(dir, src.getName());
            try (InputStream in = new FileInputStream(src);
                 OutputStream out = new FileOutputStream(dst)) {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
            Uri u = androidx.core.content.FileProvider.getUriForFile(
                    getApplicationContext(),
                    getPackageName() + ".fileprovider",
                    dst);
            String ext = MimeTypeMap.getFileExtensionFromUrl(dst.getName());
            String mime = ext == null || ext.isEmpty()
                    ? "*/*" : MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.toLowerCase());
            Intent send = new Intent(Intent.ACTION_SEND);
            send.setType(mime == null ? "*/*" : mime);
            send.putExtra(Intent.EXTRA_STREAM, u);
            send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(send, "导出到"));
            result.success(true);
        } catch (Throwable t) {
            result.error("export_failed", String.valueOf(t.getMessage()), null);
        }
    }

    /**
     * 拉起系统安装器。文件在 filesDir/updates 下，属于私有目录，
     * 必须先经 FileProvider 转成 content:// URI 并授予读权限，否则安装器读不到。
     *
     * 权限：Android 8.0+ 用 canRequestPackageInstalls() 判断「安装未知来源应用」，
     * 没开就回 need_install_permission，让 UI 引导用户去设置页。
     * targetSdk=28 不变 —— 这条路径不依赖 targetSdk。
     */
    private void installApk(MethodChannel.Result result, String path) {
        try {
            File apk = new File(path);
            if (!apk.isFile()) {
                result.error("not_found", "安装包不存在: " + path, null);
                return;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    && !getPackageManager().canRequestPackageInstalls()) {
                result.error("need_install_permission",
                        "未授予「安装未知应用」权限，请在系统设置里允许 SparkShell 安装应用", null);
                return;
            }
            Uri uri = FileProvider.getUriForFile(
                    getApplicationContext(),
                    getPackageName() + ".fileprovider",
                    apk);
            Intent i = new Intent(Intent.ACTION_VIEW);
            i.setDataAndType(uri, "application/vnd.android.package-archive");
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
            result.success(true);
        } catch (ActivityNotFoundException e) {
            result.error("no_installer", "系统里没有可用的安装器（可能被停用）", null);
        } catch (Throwable t) {
            result.error("install_failed", "调起安装器失败: " + t.getMessage(), null);
        }
    }

    /** @return "ok" 或诊断信息 */
    private String extractRootfs() throws Exception {
        File files = getApplicationContext().getFilesDir();
        File rootfs = new File(files, "rootfs");
        File marker = new File(rootfs, ".sparkshell_ready");
        if (marker.exists() && hasShell(rootfs)) return "ok";

        deleteTree(rootfs);
        if (!rootfs.mkdirs() && !rootfs.isDirectory()) return "无法创建 " + rootfs;

        File tar = new File(files, "rootfs.tar");
        long mb = 1024L * 1024L;
        try (InputStream in = getAssets().open("flutter_assets/assets/rootfs.tar");
             OutputStream out = new FileOutputStream(tar)) {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        }
        long freeBefore = files.getUsableSpace() / mb;
        if (freeBefore < tar.length() / mb + 100) {
            tar.delete();
            return "空间不足: 剩余 " + freeBefore + "MB，需要约 " + (tar.length() / mb + 120) + "MB";
        }

        Process p = new ProcessBuilder("/system/bin/toybox", "tar", "-xf",
                tar.getAbsolutePath(), "-C", rootfs.getAbsolutePath())
                .redirectErrorStream(true).start();
        StringBuilder log = new StringBuilder();
        try (BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
            String line;
            int kept = 0;
            while ((line = br.readLine()) != null) {
                if (kept++ < 6) log.append(line).append(" / ");
            }
        }
        int code = p.waitFor();
        tar.delete();

        for (String d : new String[]{"dev", "proc", "sys", "tmp", "root", "home"}) {
            new File(rootfs, d).mkdirs();
        }

        if (!hasShell(rootfs)) {
            return "解包不完整: tar退出码=" + code + " 剩余=" + (files.getUsableSpace() / mb) + "MB tar输出=" + log;
        }
        marker.createNewFile();
        return "ok";
    }

    /**
     * Alpine 的 /bin/sh 是指向 /bin/busybox 的**绝对**符号链接，在宿主上 File.exists() 会
     * 顺着链接去解析 /bin/busybox（不存在）而返回 false —— 必须单独认符号链接本身。
     */
    private static boolean hasShell(File rootfs) {
        return present(new File(rootfs, "bin/sh"))
                || present(new File(rootfs, "usr/bin/bash"))
                || present(new File(rootfs, "bin/bash"));
    }

    private static boolean present(File f) {
        if (f.exists()) return true;
        try {
            return java.nio.file.Files.isSymbolicLink(f.toPath());
        } catch (Throwable t) {
            return false;
        }
    }

    private static void deleteTree(File f) {
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) deleteTree(k);
        f.delete();
    }
}
