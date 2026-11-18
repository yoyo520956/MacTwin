#!/usr/bin/env python3
"""
push_via_api.py — 用 GitHub Git Data API 推送

为什么需要：本环境 github.com 的 443 经常连不通，但 api.github.com 稳定。
git push 走 github.com，这里改走 REST API，效果一样。

用法:
    GITHUB_TOKEN=xxx python3 tools/push_via_api.py [--owner O] [--repo R] [--branch B] [--message MSG]

行为：
  1. 读本地 HEAD 的 tree（用 git ls-tree 遍历工作区）
  2. 为每个文件创建 blob
  3. 创建 tree、commit
  4. 更新 branch ref
"""
import json
import os
import subprocess
import sys
import urllib.request
import urllib.error

API = "https://api.github.com"


def sh(args, cwd=None, check=True):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("命令失败: %s\n%s" % (" ".join(args), r.stderr[:500]))
    return r.stdout


def api(method, path, token, body=None):
    url = API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "token " + token)
    req.add_header("Accept", "application/vnd.github+json")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:600]
        raise RuntimeError("API %s %s → %s\n%s" % (method, path, e.code, detail))


def main(argv):
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print("缺少 GITHUB_TOKEN")
        return 2

    owner = "yoyo520956"
    repo = "MacTwin"
    branch = "main"
    message = "update"
    i = 1
    while i < len(argv):
        if argv[i] == "--owner": owner = argv[i + 1]; i += 2
        elif argv[i] == "--repo": repo = argv[i + 1]; i += 2
        elif argv[i] == "--branch": branch = argv[i + 1]; i += 2
        elif argv[i] == "--message": message = argv[i + 1]; i += 2
        else: i += 1

    root = sh(["git", "rev-parse", "--show-toplevel"]).strip()

    # 1) 收集所有要提交的文件（受 .gitignore 约束）
    files = sh(["git", "-c", "core.quotePath=false", "ls-files", "-z"],
               cwd=root).split("\0")
    files = [f for f in files if f]
    if not files:
        print("没有文件可提交")
        return 1
    print("待提交文件: %d 个" % len(files))

    # 2) 逐个建 blob
    entries = []
    for idx, rel in enumerate(files):
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            continue
        with open(full, "rb") as f:
            content = f.read()
        # 二进制安全：base64 交给 API 的 encoding 参数
        import base64
        blob = api("POST", "/repos/%s/%s/git/blobs" % (owner, repo), token, {
            "content": base64.b64encode(content).decode("ascii"),
            "encoding": "base64",
        })
        executable = os.access(full, os.X_OK)
        entries.append({
            "path": rel,
            "mode": "100755" if executable else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        if (idx + 1) % 10 == 0:
            print("  …已上传 %d/%d" % (idx + 1, len(files)))

    print("创建 tree…")
    tree = api("POST", "/repos/%s/%s/git/trees" % (owner, repo), token,
               {"tree": entries})

    # 3) 取父 commit
    try:
        ref = api("GET", "/repos/%s/%s/git/ref/heads/%s" % (owner, repo, branch), token)
        parent = ref["object"]["sha"]
    except RuntimeError:
        parent = None

    print("创建 commit…")
    body = {"message": message, "tree": tree["sha"]}
    if parent:
        body["parents"] = [parent]
    commit = api("POST", "/repos/%s/%s/git/commits" % (owner, repo), token, body)
    print("commit:", commit["sha"][:8])

    if parent:
        api("PATCH", "/repos/%s/%s/git/refs/heads/%s" % (owner, repo, branch), token,
            {"sha": commit["sha"]})
    else:
        api("POST", "/repos/%s/%s/git/refs" % (owner, repo), token,
            {"ref": "refs/heads/" + branch, "sha": commit["sha"]})

    print("✅ 推送完成")
    # 让本地 ref 指向新 commit，保持与远端一致
    subprocess.run(["git", "fetch", "-q", "origin", branch], cwd=root)
    subprocess.run(["git", "reset", "-q", "--soft", "origin/" + branch], cwd=root)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))