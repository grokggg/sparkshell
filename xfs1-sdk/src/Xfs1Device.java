package com.xinghuo.xfs1;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.provider.Settings;

import java.security.MessageDigest;

/** 设备指纹 + 远程校验（Android 侧，依赖 android.jar）。 */
public final class Xfs1Device {

    private final Xfs1 xfs;

    public Xfs1Device(Context ctx, byte[] appKey) {
        this.xfs = new Xfs1(appKey, ctx.getPackageName());
    }

    public String fingerprint(Context ctx) {
        String raw = String.join("|",
                Build.BRAND == null ? "" : Build.BRAND,
                Build.MODEL == null ? "" : Build.MODEL,
                Build.DEVICE == null ? "" : Build.DEVICE,
                Build.FINGERPRINT == null ? "" : Build.FINGERPRINT,
                "sdk" + Build.VERSION.SDK_INT,
                androidId(ctx),
                apkSha256(ctx));
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            return Xfs1.hex(md.digest(raw.getBytes("UTF-8")));
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /** 生成可直接 POST 给校验服务的令牌。 */
    public String issueForServer(Context ctx) throws Exception {
        String fp = fingerprint(ctx);
        long ts = System.currentTimeMillis() / 1000L;
        String payload = String.format(
                "{\"fp\":\"%s\",\"ts\":%d,\"pkg\":\"%s\",\"v\":\"%s\"}",
                fp, ts, ctx.getPackageName(), appVersion(ctx));
        return xfs.issue(payload);
    }

    public String signRequest(String path, long ts) throws Exception {
        return xfs.sign(path + "|" + ts);
    }

    private static String androidId(Context ctx) {
        try {
            return Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ANDROID_ID);
        } catch (Throwable t) {
            return "";
        }
    }

    private static String apkSha256(Context ctx) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] sig = ctx.getPackageManager()
                    .getPackageInfo(ctx.getPackageName(), PackageManager.GET_SIGNING_CERTIFICATES)
                    .signingInfo.getApkContentsSigners()[0].toByteArray();
            return Xfs1.hex(md.digest(sig));
        } catch (Throwable t) {
            return "";
        }
    }

    private static String appVersion(Context ctx) {
        try {
            return ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0).versionName;
        } catch (Throwable t) {
            return "?";
        }
    }
}
