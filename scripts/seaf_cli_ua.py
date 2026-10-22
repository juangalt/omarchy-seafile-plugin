#!/usr/bin/env python3
"""Run seaf-cli with a browser User-Agent on urllib requests.

Cloudflare (and similar) often return HTTP 403 error 1010 for the default
Python-urllib User-Agent. Seafile itself is fine; the edge blocks the client.
"""

from __future__ import annotations

import runpy
import sys
import urllib.request

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

_OrigRequest = urllib.request.Request


class Request(_OrigRequest):
    def __init__(self, url, data=None, headers=None, origin_req_host=None, unverifiable=False, method=None):
        headers = dict(headers or {})
        # urllib stores the header as "User-agent" (title-case quirks); set both.
        if not any(k.lower() == "user-agent" for k in headers):
            headers["User-Agent"] = UA
        super().__init__(
            url,
            data=data,
            headers=headers,
            origin_req_host=origin_req_host,
            unverifiable=unverifiable,
            method=method,
        )


urllib.request.Request = Request

# Preserve seaf-cli's expected argv[0] for help text / logging.
sys.argv = ["seaf-cli", *sys.argv[1:]]
runpy.run_path("/usr/bin/seaf-cli", run_name="__main__")
