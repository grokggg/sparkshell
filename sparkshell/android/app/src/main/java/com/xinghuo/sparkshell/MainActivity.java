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
import android.provider.MediaStore;
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

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 极简宿主。
 *  - PTY 通道：open/read/write/close（native 实现在 pty_bridge.c）
 *  - IO 通道：pickAndImport / pickAndImportTo / pickImages / pickFiles / pickCamera / exportFile（Activity Result）
 *    + installApk（拉起系统安装器）。pickImages、pickFiles 是聊天附件用的，固定复制进 /root/inbox；
 *    pickCamera 走系统相机，先写私有目录临时文件，再复制进 /root/inbox 并删掉临时文件。
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
    /** 拍照单独一个请求码：相机是「单张 Result」，和文件选择器的多选回包不能混在一个分支里。 */
    private static final int REQ_CAMERA = 4712;
    private static final long MAX_IMPORT = 200L * 1024 * 1024;
    /** 一次最多选 20 个：再多就不是「发个附件」，而是批量搬运，容易把容器塞满/把界面卡死。 */
    private static final int MAX_PICK = 20;
    /** 相机写盘用的私有目录（filesDir 下），交给相机 App 之前必须经 FileProvider 授权。 */
    private static final String CAMERA_TMP_DIR = "camera_tmp";

    /** 聊天附件统一落到容器的 /root/inbox，便于用户和容器内程序按固定路径找。 */
    private static final String INBOX_DIR = "/root/inbox";

    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel.Result pendingPick;   // 选择器是异步的，得先存住 Result
    private String pendingDest = "/root/import";
    /** 相机同理，但要单独存：一次只拍一张，回包直接是 String，不能跟 pendingPick 抢。 */
    private MethodChannel.Result pendingCamera;
    private File pendingCameraFile;

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
                                case "selfCheck": {
                                    // 签名自校验 + XFS-1 自检 + 设备凭证。读 APK 全文算哈希要 1–2 s，走后台线程。
                                    final MethodChannel.Result r = result;
                                    new Thread(() -> {
                                        String out;
                                        try {
                                            out = SelfCheck.run(getApplicationContext());
                                        } catch (Throwable t) {
                                            out = "{\"verdict\":\"error\",\"err\":\"" + t + "\"}";
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
                        // 聊天附件：拍一张。走系统相机，结果同样是 /root/inbox 下的容器路径。
                        case "pickCamera": {
                            openCamera(result);
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

    /**
     * 拉起系统相机拍一张，照片先落到 filesDir/camera_tmp 的临时文件。
     *
     * 为什么要 FileProvider：相机是另一个进程，它拿不到我们私有目录的 file:// 路径（7.0 起
     * 直接 FileUriExposedException）；必须换成 content:// 并显式授予写权限。
     * authority 必须用 getPackageName()+".fileprovider" —— 清单里写的是 ${applicationId}.fileprovider，
     * 而本工程的 applicationId（com.grokggg.sparkshell）和 namespace（com.xinghuo.sparkshell）
     * 并不一致，用 BuildConfig.APPLICATION_ID / 硬编码包名都会在这里炸掉。
     */
    private void openCamera(MethodChannel.Result result) {
        if (pendingCamera != null) {
            result.error("busy", "相机已经打开", null);
            return;
        }
        File shot = null;
        try {
            File dir = new File(getApplicationContext().getFilesDir(), CAMERA_TMP_DIR);
            // 老临时文件（上次被杀进程留下的）顺手清掉，避免越积越多。
            cleanCameraTmp(dir);
            if (!dir.mkdirs() && !dir.isDirectory()) {
                result.error("camera_failed", "无法创建拍照临时目录", null);
                return;
            }
            shot = new File(dir, "shot-" + System.currentTimeMillis() + ".jpg");
            Uri out = FileProvider.getUriForFile(
                    getApplicationContext(),
                    getPackageName() + ".fileprovider",
                    shot);

            Intent i = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            i.putExtra(MediaStore.EXTRA_OUTPUT, out);
            // 相机进程要往这个 URI 里写，读权限一并给（部分 ROM 会先读后写）。
            i.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);

            pendingCamera = result;
            pendingCameraFile = shot;
            try {
                startActivityForResult(i, REQ_CAMERA);
            } catch (ActivityNotFoundException e) {
                pendingCamera = null;
                pendingCameraFile = null;
                shot.delete();
                result.error("no_camera", "设备上没有可用的相机", null);
            }
        } catch (Throwable t) {
            pendingCamera = null;
            pendingCameraFile = null;
            if (shot != null) shot.delete();
            result.error("camera_failed", "调起相机失败: " + t.getMessage(), null);
        }
    }

    /** camera_tmp 里超过一天的文件直接删，正常情况拍照失败也会删，这里只是兜底。 */
    private static void cleanCameraTmp(File dir) {
        File[] old = dir.listFiles();
        if (old == null) return;
        long cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000;
        for (File f : old) {
            if (f.isFile() && f.lastModified() < cutoff) f.delete();
        }
    }

    /** 相机回包：RESULT_OK 就把临时文件复制进容器，返回容器路径；取消返回 null。 */
    private void onCameraResult(int resultCode, Intent data) {
        final MethodChannel.Result r = pendingCamera;
        final File shot = pendingCameraFile;
        pendingCamera = null;
        pendingCameraFile = null;
        if (r == null) {
            if (shot != null) shot.delete();
            return;
        }
        if (resultCode != Activity.RESULT_OK) {
            // 用户点了取消 / 按返回键：按取消处理，不留垃圾文件。
            if (shot != null) shot.delete();
            r.success(null);
            return;
        }
        if (shot == null || !shot.isFile() || shot.length() == 0) {
            // 有的 ROM 会回 RESULT_OK 但其实没写文件（相机崩了 / 没给写权限）。
            if (shot != null) shot.delete();
            r.error("camera_failed", "相机没有返回照片，请重试", null);
            return;
        }
        new Thread(() -> {
            String guest = null;
            String err = null;
            try {
                guest = importPhoto(shot, INBOX_DIR);
            } catch (Throwable t) {
                String m = t.getMessage();
                err = (m == null || m.trim().isEmpty()) ? "读取照片失败" : m.trim();
            } finally {
                // 临时文件使命结束：已经复制进 rootfs，原件删掉。
                shot.delete();
            }
            final String g = guest;
            final String e = err;
            main.post(() -> {
                if (g != null) {
                    r.success(g);
                } else {
                    r.error("import_failed", "照片复制到容器失败：" + e, null);
                }
            });
        }).start();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        // 相机与文件选择器各走各的分支，pendingPick / pendingCamera 互不影响。
        if (requestCode == REQ_CAMERA) {
            onCameraResult(resultCode, data);
            return;
        }
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
        if (uris.size() > MAX_PICK) {
            r.error("too_many", "一次最多选 " + MAX_PICK + " 个，这次选了 " + uris.size() + " 个", null);
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
        // 只认系统选择器给的两种 scheme。file:// 虽然少见，但用户从「最近」里也可能拖进来；
        // 其它（http/ftp/自定义 provider）一旦放进 openInputStream 就是任人摆布，直接拒。
        String scheme = uri.getScheme();
        if (!"content".equals(scheme) && !"file".equals(scheme)) {
            throw new Exception("不支持这种来源：" + scheme);
        }
        // 先看元数据再动流：手机相册里 300MB 的视频，不该等复制到一半才发现超限。
        long size = declaredSize(uri);
        if (size > MAX_IMPORT) {
            throw new Exception("文件超过 200MB（实际 " + (size / 1024 / 1024) + "MB）");
        }
        File target = reserveTarget(destDir, displayName(uri));
        try (InputStream in = getContentResolver().openInputStream(uri)) {
            if (in == null) throw new Exception("读不到 " + uri);
            copyStreamTo(in, target);
        }
        return guestPath(destDir, target);
    }

    /** 把相机临时文件复制进 rootfs，名字用拍照时间，便于在容器里排序辨认。 */
    private String importPhoto(File photo, String destDir) throws Exception {
        String name = "photo-"
                + new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date())
                + ".jpg";
        File target = reserveTarget(destDir, name);
        try (InputStream in = new FileInputStream(photo)) {
            copyStreamTo(in, target);
        }
        return guestPath(destDir, target);
    }

    /**
     * 在 rootfs 的 destDir 下占一个不重名的文件名（目录顺手建好）。
     * 文件和照片共用这套规则，改名/去重只有一处。
     */
    private File reserveTarget(String destDir, String name) throws Exception {
        File rootfs = new File(getApplicationContext().getFilesDir(), "rootfs");
        File dir = new File(rootfs, destDir.startsWith("/") ? destDir.substring(1) : destDir);
        if (!dir.mkdirs() && !dir.isDirectory()) throw new Exception("无法创建目录 " + dir);
        return unique(dir, sanitize(name));
    }

    /** 复制流到 target；失败或超限时把半截文件删掉，别让模型读到坏文件。 */
    private void copyStreamTo(InputStream in, File target) throws Exception {
        boolean done = false;
        try (InputStream src = in; OutputStream out = new FileOutputStream(target)) {
            byte[] buf = new byte[1 << 16];
            long total = 0;
            int n;
            while ((n = src.read(buf)) > 0) {
                total += n;
                if (total > MAX_IMPORT) throw new Exception("文件超过 200MB");
                out.write(buf, 0, n);
            }
            done = true;
        } finally {
            if (!done) target.delete();
        }
    }

    /** 容器内的绝对路径，如 /root/inbox/photo-20261119-143012.jpg。 */
    private static String guestPath(String destDir, File target) {
        String guestDir = destDir.startsWith("/") ? destDir : "/" + destDir;
        return (guestDir.endsWith("/") ? guestDir : guestDir + "/") + target.getName();
    }

    private String displayName(Uri uri) {
        String name = null;
        try (Cursor c = getContentResolver().query(
                uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) name = c.getString(idx);
            }
        } catch (Throwable ignored) {
        }
        if (name == null) name = uri.getLastPathSegment();
        return sanitize(name == null ? "unnamed" : name);
    }

    /**
     * provider 声明的文件大小；拿不到就回 -1（表示未知，交给流里那个 200MB 兜底）。
     *
     * 只投影 SIZE 一列：有的 provider 列很多、还会顺手查云端，把整行都查下来很慢。
     */
    private long declaredSize(Uri uri) {
        if (!"content".equals(uri.getScheme())) {
            try {
                File f = new File(uri.getPath() == null ? "" : uri.getPath());
                return f.exists() ? f.length() : -1L;
            } catch (Throwable ignored) {
                return -1L;
            }
        }
        try (Cursor c = getContentResolver().query(
                uri, new String[]{OpenableColumns.SIZE}, null, null, null)) {
            if (c != null && c.moveToFirst()) {
                int idx = c.getColumnIndex(OpenableColumns.SIZE);
                if (idx >= 0 && !c.isNull(idx)) return c.getLong(idx);
            }
        } catch (Throwable ignored) {
        }
        return -1L;
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

    /** rootfs 解包是全局唯一资源：同一时刻只准一个在跑，否则两个 tar 会互相删对方的 cwd。 */
    private static final Object ROOTFS_LOCK = new Object();
    private static volatile boolean sExtracting = false;

    /** @return "ok" 或诊断信息 */
    private String extractRootfs() throws Exception {
        synchronized (ROOTFS_LOCK) {
            if (sExtracting) {
                // 3.8.4 及以前没有这道闸：Linux 页 + 文件页（+ Chat / 远程）会同时发起解包，
                // 各自 deleteTree(rootfs) 把对方的 cwd 删掉，于是 tar 报
                //   "tar: ... rootfs.tar: No such file or directory"
                //   "tar: xgetcwd: No such file or directory"  "tar: './bin' bad symlink"
                // 表现就是「准备失败」反复出现，且 剩余××MB 数字忽大忽小。
                return "busy: 上一次解包还在进行，等它结束（进度看日志）";
            }
            sExtracting = true;
            try {
                return extractRootfsLocked();
            } finally {
                sExtracting = false;
            }
        }
    }

    /**
     * 真正的解包：先解到 rootfs.tmp，校验出 shell 后才原子换成 rootfs。
     * 老实现直接往 rootfs 里解，一旦中断就留下半个系统；下次再解又在旧的上面叠，
     * 加上并发就必然烂掉。临时目录 + rename 这一步是「要么完整，要么原样」的底线。
     */
    private String extractRootfsLocked() throws Exception {
        File files = getApplicationContext().getFilesDir();
        File rootfs = new File(files, "rootfs");
        File marker = new File(rootfs, ".sparkshell_ready");
        if (marker.exists() && hasShell(rootfs)) return "ok";

        File tmp = new File(files, "rootfs.tmp");
        deleteTree(tmp);
        if (!tmp.mkdirs() && !tmp.isDirectory()) return "无法创建 " + tmp;

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
            deleteTree(tmp);
            return "空间不足: 剩余 " + freeBefore + "MB，需要约 " + (tar.length() / mb + 120) + "MB";
        }

        Process p = new ProcessBuilder("/system/bin/toybox", "tar", "-xf",
                tar.getAbsolutePath(), "-C", tmp.getAbsolutePath())
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

        if (!hasShell(tmp)) {
            long freeAfter = files.getUsableSpace() / mb;
            deleteTree(tmp);
            return "解包不完整: tar退出码=" + code + " 剩余=" + freeAfter + "MB tar输出=" + log;
        }

        for (String d : new String[]{"dev", "proc", "sys", "tmp", "root", "home"}) {
            new File(tmp, d).mkdirs();
        }
        new File(tmp, ".sparkshell_ready").createNewFile();

        // 原子就位：先删旧目录，再 rename。同一分区内 rename 是原子的。
        deleteTree(rootfs);
        if (!tmp.renameTo(rootfs)) {
            // 极少数机型 rename 失败（挂载点/权限）→ 退化成「再解一次到正式目录」，至少不撒谎。
            return "解包完成但无法就位（rename 失败），请点重试";
        }
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
