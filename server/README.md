# xfs1-verify

```bash
pip install cryptography
XFS1_APP_KEY=<64 hex> XFS1_CONTEXT=com.xinghuo.sparkshell PORT=8787 python3 xfs1_server.py
curl -s localhost:8787/healthz
curl -s -X POST localhost:8787/v1/verify -d '{"token":"xfs1...."}'
```

校验：HMAC → AES-256-GCM 解密 → 时间窗 300s → 发 license。
