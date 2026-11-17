# fixtures / — CI 临时目录

这个目录里的内容**不入库**（VS Code 单文件就 370MB）。
CI 每次运行重新下载，本地分析用。

目录由 `fixtures/.gitkeep` 占位保留（否则 git 不提交空目录，
GitHub Actions 里 `cd fixtures` 会失败）。

## 本地准备

```bash
# VS Code（Electron，196MB framework）
curl -sL -o vscode.zip "$(curl -sI \
  https://update.code.visualstudio.com/latest/darwin-arm64/stable \
  | grep -i '^location' | tail -1 | tr -d '\r' | awk '{print $2}')"
mkdir -p work && cd work && unzip -q ../vscode.zip \
  "Visual Studio Code.app/Contents/MacOS/*" \
  "Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework"
cp "Visual Studio Code.app/Contents/MacOS/Code" ../vscode_Code
cp "Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework" \
   ../vscode_electron_fw
cd ..

# jq（Homebrew bottle）
mkdir -p jqwork && cd jqwork
SHA=$(curl -s https://formulae.brew.sh/api/formula/jq.json | \
  python3 -c "import json,sys;print(json.load(sys.stdin)['bottle']['stable']['files']['arm64_sonoma']['sha256'])")
TOK=$(curl -s "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/jq:pull" | \
  python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")
curl -sL -H "Authorization: Bearer $TOK" -o jq.tar.gz \
  "https://ghcr.io/v2/homebrew/core/jq/blobs/sha256:$SHA"
tar xzf jq.tar.gz jq/*/bin/jq
cp "$(find . -name jq -type f | head -1)" ../jq_macos
cd ..

# orjson（PyPI universal2 wheel）
mkdir -p orjsonwork && cd orjsonwork
python3 -m pip download --no-deps --only-binary=:all: \
  --platform macosx_11_0_arm64 --python-version 3.11 \
  --implementation cp --abi cp311 "orjson==3.10.7" -d .
unzip -q orjson-3.10.7-*.whl "orjson/*.so"
cp "$(find . -name '*.so' | head -1)" ../orjson.orig
cd ..
python3 ../tools/thin.py orjson.orig -o orjson_arm64.so --arch arm64

# 然后
python3 tools/macho.py jq_macos
python3 tools/crosscheck.py jq_macos
```