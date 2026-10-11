# /// script
# requires-python = ">=3.11"
# dependencies = ["PyJWT[crypto]>=2.10,<3"]
# ///
"""Read-only App Store Connect build status; credentials are injected by codex-secret."""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

APP_IDS = {"macos": "6816541220", "ios": "6816541067"}
API = "https://api.appstoreconnect.apple.com"


def make_token():
    names = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY")
    if any(not os.environ.get(name) for name in names):
        raise ValueError("必须配置 ASC_KEY_ID、ASC_ISSUER_ID、ASC_PRIVATE_KEY。")
    now = int(time.time())
    try:
        return jwt.encode(
            {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 600,
             "aud": "appstoreconnect-v1"},
            os.environ["ASC_PRIVATE_KEY"], algorithm="ES256",
            headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
        )
    except Exception:
        raise ValueError("无法使用 ASC_PRIVATE_KEY 签名，请检查 PKCS8 EC 私钥。") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def build_status(platform, build=None):
    filters = {
        "filter[app]": APP_IDS[platform], "sort": "-uploadedDate", "limit": "1",
        "include": "buildBetaDetail,preReleaseVersion,betaGroups",
    }
    if build is not None:
        filters["filter[version]"] = str(build)
    query = urllib.parse.urlencode(filters)
    request = urllib.request.Request(
        API + "/v1/builds?" + query,
        headers={"Authorization": "Bearer " + make_token(), "Accept": "application/json"},
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"App Store Connect HTTP {error.code}") from None
    except urllib.error.URLError:
        raise RuntimeError("无法连接 App Store Connect。") from None
    included = {(item["type"], item["id"]): item["attributes"] for item in payload.get("included", [])}
    builds = []
    for item in payload["data"]:
        attributes = item["attributes"]
        result = {"id": item["id"], **{name: attributes.get(name) for name in
                  ("version", "uploadedDate", "processingState", "expired", "expirationDate")}}
        for relation in ("buildBetaDetail", "preReleaseVersion"):
            target = item.get("relationships", {}).get(relation, {}).get("data")
            result[relation] = included.get((target["type"], target["id"])) if target else None
        groups = item.get("relationships", {}).get("betaGroups", {})
        result["betaGroups"] = [
            {"id": target["id"], **included.get((target["type"], target["id"]), {})}
            for target in groups.get("data", [])
        ] if "data" in groups else None
        result["betaGroupsHasMore"] = bool(groups.get("links", {}).get("next"))
        builds.append(result)
    return {"platform": platform, "appID": APP_IDS[platform], "builds": builds}


def wait_for_build(platform, build, version, timeout=1800):
    deadline = time.monotonic() + timeout
    while True:
        result = build_status(platform, build)
        for item in result["builds"]:
            if item["version"] != str(build):
                continue
            release = item.get("preReleaseVersion") or {}
            if release.get("version") != version:
                raise RuntimeError("上传构建的营销版本与预期不一致。")
            state = item.get("processingState")
            print(json.dumps({"version": version, "build": build, "processingState": state},
                             ensure_ascii=False), flush=True)
            if state in ("FAILED", "INVALID"):
                raise RuntimeError(f"Apple 构建处理失败：{state}")
            detail = item.get("buildBetaDetail") or {}
            if state == "VALID" and detail.get("internalBuildState") == "IN_BETA_TESTING":
                return result
        if time.monotonic() >= deadline:
            raise RuntimeError("安装包已上传，但尚未确认目标构建可用于内部测试；请检查 App Store Connect。")
        time.sleep(min(30, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=APP_IDS)
    parser.add_argument("action", choices=["status", "wait"])
    parser.add_argument("--build")
    parser.add_argument("--version")
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    if args.action == "wait" and (not args.build or not args.version or args.timeout <= 0):
        parser.error("wait 必须提供 --build、--version 及正数 --timeout。")
    try:
        result = (wait_for_build(args.platform, args.build, args.version, args.timeout)
                  if args.action == "wait" else build_status(args.platform, args.build))
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
