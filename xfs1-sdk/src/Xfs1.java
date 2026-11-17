package com.xinghuo.xfs1;

import java.io.UnsupportedEncodingException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * XFS-1（Spark Signature v1）参考实现。
 *
 * <p>设计目标：可配置密钥、无 Android 依赖（核心可在 JVM 上单测）、令牌自带完整性。
 *
 * <pre>
 *   k        = SHA-256("XFS-1" ‖ context ‖ salt[16])
 *   body     = AES-256-GCM(k, iv[12], payload, tag=128)
 *   token    = "xfs1." + b64(iv‖body) + "." + hex(HMAC-SHA256(appKey, b64))[0:32]
 * </pre>
 *
 * 其中 {@code context} 一般是包名，{@code appKey} 是 32 字节应用密钥（不进 APK 明文时可远程下发）。
 */
public final class Xfs1 {

    public static final String VERSION = "xfs1";
    private static final int IV_LEN = 12;
    private static final int TAG_BITS = 128;
    private static final int SALT_LEN = 16;

    private final byte[] appKey;
    private final String context;
    private final SecureRandom rng = new SecureRandom();

    public Xfs1(byte[] appKey, String context) {
        if (appKey == null || appKey.length != 32) {
            throw new IllegalArgumentException("appKey must be 32 bytes");
        }
        if (context == null || context.isEmpty()) {
            throw new IllegalArgumentException("context required");
        }
        this.appKey = appKey.clone();
        this.context = context;
    }

    public static Xfs1 fromHex(String keyHex, String context) {
        return new Xfs1(hexToBytes(keyHex), context);
    }

    /** 生成一个带完整性校验的令牌，payload 一般是 JSON。 */
    public String issue(String payload) throws Exception {
        byte[] salt = new byte[SALT_LEN];
        rng.nextBytes(salt);

        byte[] key = deriveKey(salt);
        byte[] iv = new byte[IV_LEN];
        rng.nextBytes(iv);

        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_BITS, iv));
        byte[] ct = c.doFinal(payload.getBytes("UTF-8"));

        byte[] blob = new byte[salt.length + iv.length + ct.length];
        System.arraycopy(salt, 0, blob, 0, salt.length);
        System.arraycopy(iv, 0, blob, salt.length, iv.length);
        System.arraycopy(ct, 0, blob, salt.length + iv.length, ct.length);

        String b64 = Base64.getEncoder().encodeToString(blob);
        byte[] mac = hmac(("xfs1." + b64).getBytes("UTF-8"));
        return "xfs1." + b64 + "." + hex(mac).substring(0, 32);
    }

    /** 校验并解出原文；任何篡改都会抛异常。 */
    public String open(String token) throws Exception {
        String[] parts = token.split("\\.");
        if (parts.length != 3 || !VERSION.equals(parts[0])) {
            throw new IllegalArgumentException("bad token format");
        }
        String b64 = parts[1];
        byte[] mac = hmac(("xfs1." + b64).getBytes("UTF-8"));
        if (!hex(mac).substring(0, 32).equalsIgnoreCase(parts[2])) {
            throw new SecurityException("HMAC mismatch");
        }

        byte[] blob = Base64.getDecoder().decode(b64);
        byte[] salt = new byte[SALT_LEN];
        byte[] iv = new byte[IV_LEN];
        System.arraycopy(blob, 0, salt, 0, SALT_LEN);
        System.arraycopy(blob, SALT_LEN, iv, 0, IV_LEN);

        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(deriveKey(salt), "AES"),
                new GCMParameterSpec(TAG_BITS, iv));
        byte[] pt = c.doFinal(blob, SALT_LEN + IV_LEN, blob.length - SALT_LEN - IV_LEN);
        return new String(pt, "UTF-8");
    }

    /** 设备绑定签名（不加密，用于请求头）。 */
    public String sign(String message) throws Exception {
        return hex(hmac(message.getBytes("UTF-8")));
    }

    public byte[] deriveKey(byte[] salt) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        md.update("XFS-1".getBytes("UTF-8"));
        md.update(context.getBytes("UTF-8"));
        md.update(salt);
        return md.digest();
    }

    private byte[] hmac(byte[] msg) throws Exception {
        Mac m = Mac.getInstance("HmacSHA256");
        m.init(new SecretKeySpec(appKey, "HmacSHA256"));
        return m.doFinal(msg);
    }

    public static String hex(byte[] in) {
        StringBuilder sb = new StringBuilder(in.length * 2);
        for (byte b : in) {
            sb.append(Character.forDigit((b >> 4) & 0xF, 16));
            sb.append(Character.forDigit(b & 0xF, 16));
        }
        return sb.toString();
    }

    public static byte[] hexToBytes(String hex) {
        int n = hex.length() / 2;
        byte[] out = new byte[n];
        for (int i = 0; i < n; i++) {
            out[i] = (byte) Integer.parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        }
        return out;
    }
}
