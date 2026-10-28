#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
装修预算 · 协同编辑服务
兼容 Python 3.6 / CentOS-Rocky 8 自带解释器，仅用标准库。

接口
  GET  /                 前端单页
  GET  /api/data         读数据（需口令）  -> {v, ts, who, rate, rows[]}
  PUT  /api/data         写数据（需口令）  body: {base_v, rows[], rate, who, todos[]}
                          200 -> {v, ts, who}   409 -> {error:"conflict", data:{...}}
  POST /api/upload       上传待办配图（需口令）body: 图片二进制
                          -> {url}  路径形如 img/<随机>.<ext>
  GET  /img/<name>       读取配图（免口令，文件名随机不可猜）
  GET  /api/health       健康检查（免口令）

存储
  data.json   原子写入（tmp + os.replace），每次写入前保留 data.json.bak
  口令取 secret.txt 首行（不存在则自动生成）
"""
import json
import mimetypes
import os
import secrets
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

BASE = os.path.dirname(os.path.abspath(__file__))
DATA_PATH = os.path.join(BASE, "data.json")
BAK_PATH = os.path.join(BASE, "data.json.bak")
SECRET_PATH = os.path.join(BASE, "secret.txt")
HTML_PATH = os.path.join(BASE, "index.html")
IMG_DIR = os.path.join(BASE, "img")

MAX_BODY = 4 * 1024 * 1024          # 4MB
MAX_IMG = 3 * 1024 * 1024           # 单张图片 3MB
MAX_ROWS = 2000
MAX_TODOS = 200
LOCK = threading.Lock()

ROW_FIELDS = ("cat", "name", "qty", "unit", "price", "extra",
              "brand", "spec", "sup", "prog", "note")
NUM_FIELDS = ("qty", "price", "extra")
IMG_TYPES = {"image/jpeg": ".jpg", "image/png": ".png",
             "image/webp": ".webp", "image/gif": ".gif"}


def now_iso():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def get_secret():
    if os.path.exists(SECRET_PATH):
        with open(SECRET_PATH, "r", encoding="utf-8") as f:
            s = f.read().strip()
            if s:
                return s
    s = secrets.token_urlsafe(9)
    with open(SECRET_PATH, "w", encoding="utf-8") as f:
        f.write(s + "\n")
    return s


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def read_data():
    if not os.path.exists(DATA_PATH):
        return {"v": 0, "ts": now_iso(), "who": "", "rate": 5, "rows": [], "todos": []}
    return read_json(DATA_PATH)


def write_data(obj):
    tmp = DATA_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.flush()
        os.fsync(f.fileno())
    if os.path.exists(DATA_PATH):
        try:
            with open(DATA_PATH, "r", encoding="utf-8") as src, \
                    open(BAK_PATH, "w", encoding="utf-8") as dst:
                dst.write(src.read())
        except OSError:
            pass
    os.replace(tmp, DATA_PATH)


def sanitize_rows(raw):
    out = []
    if not isinstance(raw, list):
        return out
    for i, r in enumerate(raw[:MAX_ROWS]):
        if not isinstance(r, dict):
            continue
        row = {"id": str(r.get("id") or ("r%d" % (i + 1)))}
        for k in ROW_FIELDS:
            v = r.get(k, "")
            if k in NUM_FIELDS:
                try:
                    v = float(v) if v not in ("", None) else 0
                except (TypeError, ValueError):
                    v = 0
                if v == int(v):
                    v = int(v)
            else:
                v = "" if v is None else str(v)[:500]
            row[k] = v
        out.append(row)
    return out


def sanitize_todos(raw):
    """待办列表：文字 + 截止日 + 可选配图（站内相对路径）。"""
    out = []
    if not isinstance(raw, list):
        return out
    for i, t in enumerate(raw[:MAX_TODOS]):
        if not isinstance(t, dict):
            continue
        out.append({
            "id": str(t.get("id") or ("t%d" % (i + 1)))[:40],
            "text": str(t.get("text") or "").strip()[:200],
            "due": str(t.get("due") or "")[:10],
            "img": str(t.get("img") or "")[:200],
            "by": str(t.get("by") or "")[:20],
            "done": bool(t.get("done")),
        })
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "BudgetApp/1.0"
    protocol_version = "HTTP/1.1"

    # ---------- helpers ----------
    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        extra = extra or {}
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", extra.get("Cache-Control", "no-store"))
        for k, v in extra.items():
            if k.lower() == "cache-control":
                continue
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False), "application/json; charset=utf-8")

    def _authed(self, qs):
        tok = self.headers.get("X-Auth", "") or (qs.get("k", [""])[0])
        return bool(tok) and secrets.compare_digest(tok, get_secret())

    def log_message(self, fmt, *args):
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    # ---------- routes ----------
    def do_GET(self):
        u = urlparse(self.path)
        path = u.path
        qs = parse_qs(u.query)

        if path in ("/", "/index.html"):
            try:
                with open(HTML_PATH, "rb") as f:
                    html = f.read()
            except OSError:
                return self._send(500, "index.html missing", "text/plain; charset=utf-8")
            return self._send(200, html, "text/html; charset=utf-8")

        if path == "/api/health":
            d = read_data()
            return self._json(200, {"ok": True, "v": d.get("v", 0)})

        if path == "/api/data":
            if not self._authed(qs):
                return self._json(401, {"error": "auth"})
            return self._json(200, read_data())

        if path == "/favicon.ico":
            return self._send(204, "")

        if path.startswith("/img/"):
            name = os.path.basename(path)
            if not name or name.startswith("."):
                return self._send(404, '{"error":"not found"}')
            fp = os.path.join(IMG_DIR, name)
            if not os.path.isfile(fp):
                return self._send(404, '{"error":"not found"}')
            try:
                with open(fp, "rb") as f:
                    blob = f.read()
            except OSError:
                return self._send(500, '{"error":"read"}')
            ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
            # 文件名是随机串，内容不会变，允许长缓存
            return self._send(200, blob, ctype, {"Cache-Control": "public, max-age=604800"})

        return self._send(404, '{"error":"not found"}')

    def do_POST(self):
        """图片上传：直接收二进制，存成随机文件名，返回站内相对路径。"""
        u = urlparse(self.path)
        if u.path != "/api/upload":
            return self._send(404, '{"error":"not found"}')
        if not self._authed(parse_qs(u.query)):
            return self._json(401, {"error": "auth"})

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_IMG:
            return self._json(400, {"error": "bad length"})
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        ext = IMG_TYPES.get(ctype)
        if not ext:
            return self._json(400, {"error": "bad type"})

        data = self.rfile.read(length)
        if len(data) != length:
            return self._json(400, {"error": "short body"})
        try:
            os.makedirs(IMG_DIR, exist_ok=True)
            name = secrets.token_hex(9) + ext
            with open(os.path.join(IMG_DIR, name), "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
        except OSError:
            return self._json(500, {"error": "write"})
        return self._json(200, {"url": "img/" + name, "size": len(data)})

    def do_PUT(self):
        u = urlparse(self.path)
        if u.path != "/api/data":
            return self._send(404, '{"error":"not found"}')
        if not self._authed(parse_qs(u.query)):
            return self._json(401, {"error": "auth"})

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return self._json(400, {"error": "bad length"})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return self._json(400, {"error": "bad json"})

        with LOCK:
            cur = read_data()
            base_v = payload.get("base_v")
            if base_v is not None and int(base_v) != int(cur.get("v", 0)):
                return self._json(409, {"error": "conflict", "data": cur})
            try:
                rate = float(payload.get("rate", cur.get("rate", 5)))
            except (TypeError, ValueError):
                rate = 5
            new = {
                "v": int(cur.get("v", 0)) + 1,
                "ts": now_iso(),
                "who": str(payload.get("who", "") or "")[:20],
                "rate": rate,
                "title": str(payload.get("title") or cur.get("title") or "装修预算")[:60],
                "rows": sanitize_rows(payload.get("rows")),
                "todos": sanitize_todos(payload.get("todos", cur.get("todos", []))),
            }
            write_data(new)
        return self._json(200, {"v": new["v"], "ts": new["ts"], "who": new["who"]})

    def do_HEAD(self):
        self.do_GET()


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
    get_secret()
    if not os.path.exists(DATA_PATH):
        write_data({"v": 0, "ts": now_iso(), "who": "", "rate": 5,
                    "title": "装修预算", "rows": [], "todos": []})
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stdout.write("budget app listening on 127.0.0.1:%d\n" % port)
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
