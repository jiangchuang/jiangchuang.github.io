#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""budget 应用冒烟测试（纯标准库，兼容 Python 3.6）。

    python3 smoke_test.py http://127.0.0.1:8099 <口令>

⚠️ 会写数据（改 v、插几行、传一张假图）。**只对测试实例跑**，别指线上 /opt/budget。
   线上验证用只读的 check_prod.sh。
"""
import json
import sys
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8099").rstrip("/")
KEY = sys.argv[2] if len(sys.argv) > 2 else ""
ok = fail = 0
FAILS = []


def req(method, path, body=None, headers=None, raw=False):
    h = {"X-Auth": KEY}
    if headers:
        h.update(headers)
    data = None
    if body is not None:
        data = body if raw else json.dumps(body).encode("utf-8")
        h.setdefault("Content-Type", "application/json")
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    # 绕开系统代理，否则本机请求可能被 http_proxy 拦走
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(r, timeout=10) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def check(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
        print("  [PASS] %s %s" % (name, detail))
    else:
        fail += 1
        FAILS.append(name)
        print("  [FAIL] %s %s" % (name, detail))


def main():
    if not KEY:
        print("用法: python3 smoke_test.py <base_url> <口令>")
        return 2

    print("== 鉴权 ==")
    s, _, _ = req("GET", "/api/data", headers={"X-Auth": ""})
    check("无口令 -> 401", s == 401, "(实际 %d)" % s)

    s, h, b = req("GET", "/api/data")
    check("正确口令 -> 200", s == 200, "(实际 %d)" % s)
    etag = h.get("ETag", "")
    check("带 ETag", bool(etag), etag)
    d = json.loads(b)
    v0 = d.get("v", 0)
    print("     v=%s rows=%d 载荷=%dB" % (v0, len(d.get("rows", [])), len(b)))

    print("== 304 协商 ==")
    s, _, b304 = req("GET", "/api/data", headers={"If-None-Match": etag})
    check("命中 -> 304", s == 304, "(实际 %d)" % s)
    check("304 无 body", len(b304) == 0, "(%dB)" % len(b304))
    s, _, _ = req("GET", "/api/data", headers={"If-None-Match": 'W/"d-0-x-x"'})
    check("不匹配 -> 200", s == 200, "(实际 %d)" % s)

    print("== 乐观锁 ==")
    payload = {"base_v": v0, "rows": d.get("rows", []), "rate": d.get("rate", 5),
               "who": "smoke", "todos": d.get("todos", []), "title": d.get("title", "装修预算")}
    s, _, b = req("PUT", "/api/data", payload)
    check("正确 base_v -> 200", s == 200, "(实际 %d)" % s)
    if s == 200:
        new = json.loads(b)
        check("v 自增", new.get("v") == v0 + 1, "v=%s" % new.get("v"))
        check("回传 ETag", bool(new.get("etag")), new.get("etag", ""))
    s, _, b = req("PUT", "/api/data", payload)
    check("重复旧 base_v -> 409", s == 409, "(实际 %d)" % s)
    p2 = dict(payload, base_v="abc")
    s, _, _ = req("PUT", "/api/data", p2)
    check("base_v 非法 -> 400", s == 400, "(实际 %d)" % s)

    print("== 上传校验 ==")
    fake = b"<html><script>alert(1)</script></html>"
    s, _, _ = req("POST", "/api/upload", body=fake, raw=True,
                  headers={"Content-Type": "image/jpeg"})
    check("HTML 冒充 jpg -> 400", s == 400, "(实际 %d)" % s)
    png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + b"\x00" * 200
    s, _, b = req("POST", "/api/upload", body=png, raw=True,
                  headers={"Content-Type": "image/jpeg"})
    url = (json.loads(b).get("url", "") if s == 200 else "")
    check("真 PNG -> 200 且按真实类型存 .png",
          s == 200 and url.endswith(".png"), "(status=%d url=%s)" % (s, url))

    print("== 其他 ==")
    s, _, b = req("GET", "/robots.txt", headers={"X-Auth": ""})
    check("robots.txt 禁爬", s == 200 and b"Disallow: /" in b, "(实际 %d)" % s)

    print("== id 去重 ==")
    dup = [{"id": "same", "cat": "A", "name": "1", "qty": 1, "price": 1},
           {"id": "same", "cat": "B", "name": "2", "qty": 1, "price": 1}]
    s, _, b = req("GET", "/api/data")
    cur = json.loads(b)
    req("PUT", "/api/data", {"base_v": cur["v"], "rows": dup,
                             "rate": 5, "who": "smoke", "todos": []})
    s, _, b = req("GET", "/api/data")
    ids = [r["id"] for r in json.loads(b).get("rows", [])]
    check("重复 id 被拆开", len(ids) == len(set(ids)), "ids=%s" % ids)

    print("\n结果：%d 通过 / %d 失败" % (ok, fail))
    if FAILS:
        print("失败项：" + "、".join(FAILS))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
