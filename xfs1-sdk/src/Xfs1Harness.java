import com.xinghuo.xfs1.Xfs1;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** JVM 端到端自检：生成 XFS-1 令牌 → 打本机校验服务 → 打印 license。 */
public class Xfs1Harness {
    public static void main(String[] args) throws Exception {
        String keyHex = "9f2c41d7a83b06e5c1d94f7b28ae6305d4b81c9f7a2e5d30c6b94f1a8e7d2c05";
        String ctx = "com.xinghuo.sparkshell";
        Xfs1 xfs = Xfs1.fromHex(keyHex, ctx);

        String fp = java.util.UUID.randomUUID().toString().replace("-", "");
        long ts = System.currentTimeMillis() / 1000L;
        String payload = String.format(
                "{\"fp\":\"%s\",\"ts\":%d,\"pkg\":\"%s\",\"v\":\"1.0.0\"}", fp, ts, ctx);

        String token = xfs.issue(payload);
        System.out.println("payload   : " + payload);
        System.out.println("token     : " + token.substring(0, 60) + "…(" + token.length() + " chars)");
        System.out.println("roundtrip : " + xfs.open(token));

        // 篡改一个字节，必须解不开
        char[] t = token.toCharArray();
        t[10] = t[10] == 'A' ? 'B' : 'A';
        try {
            xfs.open(new String(t));
            System.out.println("tamper    : FAILED (篡改后仍通过)");
        } catch (Exception e) {
            System.out.println("tamper    : rejected (" + e.getClass().getSimpleName() + ")");
        }

        String base = args.length > 0 ? args[0] : "http://127.0.0.1:8787";
        HttpURLConnection c = (HttpURLConnection) new URL(base + "/v1/verify").openConnection();
        c.setRequestMethod("POST");
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/json");
        String body = "{\"token\":\"" + token + "\"}";
        try (OutputStream os = c.getOutputStream()) {
            os.write(body.getBytes(StandardCharsets.UTF_8));
        }
        int code = c.getResponseCode();
        InputStream is = code >= 400 ? c.getErrorStream() : c.getInputStream();
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = is.read(buf)) > 0) bos.write(buf, 0, n);
        System.out.println("server    : HTTP " + code + " " + bos.toString("UTF-8"));
    }
}
