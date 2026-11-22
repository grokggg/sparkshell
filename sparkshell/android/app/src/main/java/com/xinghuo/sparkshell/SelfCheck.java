package com.xinghuo.sparkshell;

import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.os.Build;
import android.provider.Settings;

import com.xinghuo.xfs1.Xfs1;

import java.security.MessageDigest;

/**
 * 自检验（3.9.0）。
 *
 * <p>三件事，全在 Java 层：
 * <ol>
 *   <li>签名自校验 —— 取本 APK 的签名证书 DER，算 SHA-256，跟编译期常量比对。
 *       重签过的包（换 keystore / 二次打包）在这里必然对不上。</li>
 *   <li>XFS-1 自检 —— 用应用密钥发一个令牌再解回来，对不上说明算法/密钥被改。</li>
 *   <li>设备凭证 —— 指纹（品牌/型号/设备/指纹/API/ANDROID_ID/APK-SHA256）打包成
 *       XFS-1 令牌，可直接 POST 给 server/xfs1_server.py 校验。</li>
 * </ol>
 *
 * <p>为什么不是 native：这一版只有 Java。搬进 .so 要 NDK 编译 + JNI + 每 ABI 一份，
 * 且 CI 目前只产 arm64-v8a；那是 3.10 的事。Java 层能被 jadx 读出来，这点不装。
 */
public final class SelfCheck {

    /**
     * 本包签名证书（CN=SparkShell,O=Xinghuo）DER 的 SHA-256。
     * 来源：android/keystore/sparkshell.jks（PKCS#12，口令 sparkshell）。
     * 换 keystore 就必须同步改这一行，否则新包自检会失败 —— 这正是它存在的意义。
     */
    public static final String EXPECTED_CERT_SHA256 =
            "108965710f9fd562757213b4f30ca1baefb4e17e3420e6b748ded8f998c0a83e";

    /** XFS-1 应用密钥（32B），与 server/xfs1_server.py 的 APP_KEY 同一把，XOR 掩码存。 */
    private static final byte[] KEY_MASK = {
            0x0b, 0x30, 0x55, 0x7a, (byte) 0x9f, (byte) 0xc4, (byte) 0xe9, 0x0e,
            0x33, 0x58, 0x7d, (byte) 0xa2, (byte) 0xc7, (byte) 0xec, 0x11, 0x36,
            0x5b, (byte) 0x80, (byte) 0xa5, (byte) 0xca, (byte) 0xef, 0x14, 0x39, 0x5e,
            (byte) 0x83, (byte) 0xa8, (byte) 0xcd, (byte) 0xf2, 0x17, 0x3c, 0x61, (byte) 0x86,
    };
    private static final byte[] KEY_MASKED = {
            (byte) 0x94, 0x1c, 0x14, (byte) 0xad, 0x37, (byte) 0xff, (byte) 0xef, (byte) 0xeb,
            (byte) 0xf2, (byte) 0x81, 0x32, (byte) 0xd9, (byte) 0xef, 0x42, 0x72, 0x33,
            (byte) 0x8f, 0x38, (byte) 0xb9, 0x55, (byte) 0x95, 0x3a, 0x64, 0x6e,
            0x45, 0x11, (byte) 0x82, (byte) 0xe8, (byte) 0x99, 0x41, 0x4d, (byte) 0x83,
    };

    private static String cachedApkSha;
    private static String cachedVerdict;

    private SelfCheck() {
    }

    private static byte[] appKey() {
        byte[] k = new byte[32];
        for (int i = 0; i < 32; i++) {
            k[i] = (byte) (KEY_MASKED[i] ^ KEY_MASK[i]);
        }
        return k;
    }

    /** APK 签名证书 DER 的 SHA-256；取不到返回 "none"。 */
    public static String certSha256(Context ctx) {
        try {
            PackageManager pm = ctx.getPackageManager();
            PackageInfo pi = pm.getPackageInfo(ctx.getPackageName(), PackageManager.GET_SIGNATURES);
            Signature[] sigs = pi.signatures;
            if (sigs == null || sigs.length == 0) return "none";
            return sha256Hex(sigs[0].toByteArray());
        } catch (Throwable t) {
            return "none";
        }
    }

    /** 装出来的 APK 文件本身的 SHA-256（慢，约 1–2 s，只在后台线程调）。 */
    public static String apkSha256(Context ctx) {
        if (cachedApkSha != null) return cachedApkSha;
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            java.io.File f = new java.io.File(ctx.getPackageCodePath());
            try (java.io.InputStream in = new java.io.FileInputStream(f)) {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            }
            cachedApkSha = hex(md.digest());
        } catch (Throwable t) {
            cachedApkSha = "none";
        }
        return cachedApkSha;
    }

    /** 设备指纹：同机同版本稳定，换机/换包就变。 */
    public static String fingerprint(Context ctx) {
        String androidId;
        try {
            androidId = Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ANDROID_ID);
        } catch (Throwable t) {
            androidId = "";
        }
        String raw = (Build.BRAND == null ? "" : Build.BRAND) + "|"
                + (Build.MODEL == null ? "" : Build.MODEL) + "|"
                + (Build.DEVICE == null ? "" : Build.DEVICE) + "|"
                + (Build.FINGERPRINT == null ? "" : Build.FINGERPRINT) + "|"
                + "sdk" + Build.VERSION.SDK_INT + "|"
                + (androidId == null ? "" : androidId) + "|"
                + apkSha256(ctx);
        return sha256Hex(raw.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }

    /**
     * 跑一遍三项检查，返回 JSON（Dart 侧直接 jsonDecode）：
     * {"cert":"…","certOk":true,"xfsOk":true,"fp":"…","token":"xfs1…","pkg":"…","ver":"3.9.0","verdict":"ok"}
     */
    public static String run(Context ctx) {
        if (cachedVerdict != null) return cachedVerdict;
        String cert = certSha256(ctx);
        boolean certOk = EXPECTED_CERT_SHA256.equalsIgnoreCase(cert);

        boolean xfsOk = false;
        String token = "";
        String fp = "";
        try {
            Xfs1 xfs = new Xfs1(appKey(), ctx.getPackageName());
            String probe = "xfs1-probe|" + ctx.getPackageName();
            String sealed = xfs.issue(probe);
            xfsOk = probe.equals(xfs.open(sealed)) && xfs.sign("ping").length() == 64;

            fp = fingerprint(ctx);
            String payload = String.format(
                    "{\"fp\":\"%s\",\"ts\":%d,\"pkg\":\"%s\",\"v\":\"%s\"}",
                    fp, System.currentTimeMillis() / 1000L, ctx.getPackageName(), versionName(ctx));
            token = xfs.issue(payload);
            // 自己解一遍：令牌里必须能解回同一指纹，否则算法层已经坏了
            xfsOk = xfsOk && xfs.open(token).contains(fp);
        } catch (Throwable t) {
            xfsOk = false;
        }

        String ver = versionName(ctx);
        String verdict = certOk && xfsOk ? "ok" : (certOk ? "xfs-broken" : "repackaged");
        String json = "{\"cert\":\"" + cert + "\",\"certOk\":" + certOk
                + ",\"xfsOk\":" + xfsOk
                + ",\"fp\":\"" + fp + "\",\"token\":\"" + token + "\","
                + "\"pkg\":\"" + ctx.getPackageName() + "\",\"ver\":\"" + ver + "\","
                + "\"verdict\":\"" + verdict + "\"}";
        cachedVerdict = json;
        return json;
    }

    private static String versionName(Context ctx) {
        try {
            PackageInfo pi = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
            return pi.versionName == null ? "?" : pi.versionName;
        } catch (Throwable t) {
            return "?";
        }
    }

    public static String sha256Hex(byte[] in) {
        try {
            return hex(MessageDigest.getInstance("SHA-256").digest(in));
        } catch (Exception e) {
            return "none";
        }
    }

    public static String hex(byte[] in) {
        StringBuilder sb = new StringBuilder(in.length * 2);
        for (byte b : in) {
            sb.append(Character.forDigit((b >> 4) & 0xF, 16));
            sb.append(Character.forDigit(b & 0xF, 16));
        }
        return sb.toString();
    }
}
