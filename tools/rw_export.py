#!/usr/bin/env python3
"""
Выгрузка конфигурации Remnawave через API с маскировкой секретов.

Запуск:
    RW_URL=https://panel.example.com RW_TOKEN=<API-токен> python3 rw_export.py

Результат: папка rw-export/ (raw/ НЕ отправлять, masked/ — можно отправлять)
и архив rw-export-masked.zip.

Маскировка согласованная: одинаковое значение везде заменяется одной и той же
меткой (IP_03, UUID_12, SECRET_05), поэтому связи между профилями, хостами
и нодами остаются видны, а сами секреты и адреса — нет.
Только стандартная библиотека Python, ничего ставить не нужно.
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ENDPOINTS = {
    "nodes": "/api/nodes",
    "hosts": "/api/hosts",
    "config-profiles": "/api/config-profiles",
    "internal-squads": "/api/internal-squads",
    "external-squads": "/api/external-squads",
    "subscription-templates": "/api/subscription-templates",
    "subscription-settings": "/api/subscription-settings",
}

# Ключи, значения которых считаем секретами целиком
SECRET_KEYS = {
    "privatekey", "shortids", "shortid", "password", "secret", "secretkey",
    "token", "apikey", "api_key", "vlessuuid", "trojanpassword", "sspassword",
    "seed", "psk", "presharedkey", "auth", "authstr", "obfspassword",
    "mldsa65seed", "decryption", "encryption",
}

UUID_RE = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
IPV4_RE = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")
KEEP_IPS = {"0.0.0.0", "127.0.0.1", "1.1.1.1", "8.8.8.8", "1.0.0.1", "8.8.4.4"}
PRIVATE_IP_RE = re.compile(r"^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.)")


class Masker:
    def __init__(self):
        self.maps = {"IP": {}, "UUID": {}, "SECRET": {}}

    def _label(self, kind, value):
        m = self.maps[kind]
        if value not in m:
            m[value] = f"{kind}_{len(m) + 1:02d}"
        return m[value]

    def text(self, s):
        s = UUID_RE.sub(lambda mo: self._label("UUID", mo.group(0).lower()), s)

        def ip(mo):
            v = mo.group(0)
            if v in KEEP_IPS or PRIVATE_IP_RE.match(v):
                return v
            return self._label("IP", v)

        return IPV4_RE.sub(ip, s)

    def value(self, v, key=None):
        k = (key or "").lower().replace("-", "").replace("_", "")
        if k in SECRET_KEYS and v not in (None, "", [], {}, "none"):
            if isinstance(v, list):
                return [x if x in ("", "none") else self._label("SECRET", json.dumps(x)) for x in v]
            return self._label("SECRET", json.dumps(v))
        if isinstance(v, dict):
            return {kk: self.value(vv, kk) for kk, vv in v.items()}
        if isinstance(v, list):
            return [self.value(x, key) for x in v]
        if isinstance(v, str):
            # строка может содержать вложенный JSON/YAML (шаблоны подписок)
            return self.text(v)
        return v


def fetch(base, token, path, cookie=None):
    ctx = ssl.create_default_context()
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "rw-export/1.1",
    }
    if cookie:
        headers["Cookie"] = cookie
    req = urllib.request.Request(base.rstrip("/") + path, headers=headers)
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        return json.loads(r.read().decode())


def describe_http_error(e):
    try:
        body = e.read().decode(errors="replace")
    except Exception:  # noqa: BLE001
        body = ""
    body = " ".join(body.split())[:300]
    server = e.headers.get("Server", "?") if e.headers else "?"
    www = e.headers.get("WWW-Authenticate") if e.headers else None
    parts = [f"HTTP {e.code}", f"Server: {server}"]
    if www:
        parts.append(f"WWW-Authenticate: {www}")
    if body:
        parts.append(f"ответ: {body}")
    return "; ".join(parts)


def main():
    base = (os.environ.get("RW_URL") or "").strip().strip('"').strip("'")
    token = (os.environ.get("RW_TOKEN") or "").strip().strip('"').strip("'")
    if token.lower().startswith("bearer "):
        token = token[7:].strip()
    cookie = (os.environ.get("RW_COOKIE") or "").strip() or None
    if not base or not token:
        sys.exit("Задайте RW_URL и RW_TOKEN (см. шапку скрипта).")
    print(
        f"Панель: {base}\nТокен: длина {len(token)}, начинается с '{token[:6]}...'"
        + ("\nCookie: задан" if cookie else "")
        + "\n"
    )
    if not token.startswith("eyJ"):
        sys.exit(
            "Токен повреждён: API-токен Remnawave (JWT) всегда начинается с 'eyJ'.\n"
            "Скорее всего, при копировании потерялся первый символ. Скопируйте токен заново."
        )

    out = Path("rw-export")
    raw_dir, masked_dir = out / "raw", out / "masked"
    raw_dir.mkdir(parents=True, exist_ok=True)
    masked_dir.mkdir(parents=True, exist_ok=True)

    masker = Masker()
    report = []
    for name, path in ENDPOINTS.items():
        try:
            data = fetch(base, token, path, cookie)
        except urllib.error.HTTPError as e:
            report.append(f"{name}: пропущено ({describe_http_error(e)})")
            continue
        except Exception as e:  # noqa: BLE001
            report.append(f"{name}: ошибка ({e})")
            continue
        data = data.get("response", data) if isinstance(data, dict) else data
        (raw_dir / f"{name}.json").write_text(
            json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        (masked_dir / f"{name}.json").write_text(
            json.dumps(masker.value(data), ensure_ascii=False, indent=2), encoding="utf-8"
        )
        report.append(f"{name}: ok")

        # Список шаблонов приходит без содержимого — догружаем каждый по UUID
        if name == "subscription-templates" and isinstance(data, dict):
            tdir_raw, tdir_masked = raw_dir / "templates", masked_dir / "templates"
            tdir_raw.mkdir(exist_ok=True)
            tdir_masked.mkdir(exist_ok=True)
            for t in data.get("templates", []):
                uid = t.get("uuid")
                fname = re.sub(r"[^\w.-]+", "_", f"{t.get('templateType')}_{t.get('name')}_{uid[:8]}")
                try:
                    full = fetch(base, token, f"{path}/{uid}", cookie)
                except Exception as e:  # noqa: BLE001
                    report.append(f"  шаблон {fname}: ошибка ({e})")
                    continue
                full = full.get("response", full)
                enc = full.get("encodedTemplateYaml") if isinstance(full, dict) else None
                if enc:
                    import base64
                    try:
                        full["templateYaml"] = base64.b64decode(enc).decode("utf-8")
                        full.pop("encodedTemplateYaml")
                    except Exception:  # noqa: BLE001
                        pass
                (tdir_raw / f"{fname}.json").write_text(
                    json.dumps(full, ensure_ascii=False, indent=2), encoding="utf-8"
                )
                (tdir_masked / f"{fname}.json").write_text(
                    json.dumps(masker.value(full), ensure_ascii=False, indent=2), encoding="utf-8"
                )
                report.append(f"  шаблон {fname}: ok")

    (masked_dir / "_report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")

    zip_path = Path("rw-export-masked.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in masked_dir.rglob("*"):
            if f.is_file():
                z.write(f, f.relative_to(masked_dir).as_posix())

    print("\n".join(report))
    print(
        f"\nГотово. Отправлять: {zip_path.resolve()}\n"
        f"Папку {raw_dir.resolve()} НЕ отправлять — там настоящие ключи, "
        "это ваш бэкап, положите в приватный репозиторий."
    )
    print(
        f"Замаскировано: IP — {len(masker.maps['IP'])}, UUID — {len(masker.maps['UUID'])}, "
        f"секретов — {len(masker.maps['SECRET'])}."
    )


if __name__ == "__main__":
    main()