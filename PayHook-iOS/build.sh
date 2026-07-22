#!/bin/bash
# PayHook v3.0 - 自动版本号递增构建脚本 (by yZFAIU)
# 用法: cd XJWeChatPay_v3.0 && ./build.sh
# 适用于 iOS 设备 on-device theos (NewTerm) 或 macOS

set -e

cd "$(dirname "$0")"
export THEOS="${THEOS:-$HOME/theos}"
export THEOS_SDKS_PATH="${THEOS_SDKS_PATH:-$HOME/theos/sdks}"

# 读取当前 build 号
BUILD_FILE=".buildnum"
BUILD=$(cat "$BUILD_FILE" 2>/dev/null || echo "1")
BASE_VERSION="3.0.0"
NEW_VERSION="${BASE_VERSION}-${BUILD}"
PARENT_DIR="$(dirname "$PWD")"

echo "============================================"
echo "  PayHook Build #${BUILD}"
echo "  Version: ${NEW_VERSION}"
echo "============================================"

# 更新 control 文件版本号 (兼容 GNU/BSD sed)
sed -i.bak "s/^Version:.*/Version: ${NEW_VERSION}/" control && rm -f control.bak

# 编译（DEBUG=0 避免 theos 加 +debug 后缀）
make clean
make package DEBUG=0

# 查找实际生成的 deb
ACTUAL_DEB=$(ls packages/com.xj.wechatpay_${NEW_VERSION}*_iphoneos-arm.deb 2>/dev/null | head -1)

if [ -z "$ACTUAL_DEB" ]; then
    echo "[ERROR] deb not found in packages/"
    exit 1
fi

echo "[FOUND] $ACTUAL_DEB"

DYLIB_FILE="PayHook_v${NEW_VERSION}.dylib"
DEB_FILE="PayHook_v${NEW_VERSION}.deb"

cp "$ACTUAL_DEB" "$PARENT_DIR/${DEB_FILE}"
echo "[OK] $PARENT_DIR/${DEB_FILE}"

# 从 deb 提取 dylib (兼容 lzma / gzip 压缩的 data.tar)
python3 - "$PARENT_DIR/${DEB_FILE}" "$PARENT_DIR/${DYLIB_FILE}" <<'PY'
import sys, io, shutil, tarfile, lzma, gzip, os

deb_path, dylib_out = sys.argv[1], sys.argv[2]

def decompress(raw):
    # 先尝试 lzma，再尝试 gzip
    try:
        return lzma.decompress(raw)
    except Exception:
        pass
    try:
        return gzip.decompress(raw)
    except Exception:
        pass
    return raw

with open(deb_path, "rb") as f:
    data = f.read()

pos = 8
while pos < len(data):
    name = data[pos:pos+16].rstrip(b" ").decode("ascii", errors="ignore")
    size = int(data[pos+48:pos+58].rstrip(b" "))
    pos += 60
    if name.startswith("data.tar"):
        raw = data[pos:pos+size]
        decompressed = decompress(raw)
        with tarfile.open(fileobj=io.BytesIO(decompressed)) as tar:
            for m in tar.getmembers():
                if m.name.endswith("XJWeChatPay.dylib") or "XJWeChatPay.dylib" in m.name:
                    f = tar.extractfile(m)
                    with open(dylib_out, "wb") as o:
                        shutil.copyfileobj(f, o)
                    print(f"[OK] {m.name} ({m.size} bytes)")
    pos += size
    if pos % 2:
        pos += 1
PY

echo "[OK] $PARENT_DIR/${DYLIB_FILE}"

# 递增 build 号
echo "$((BUILD + 1))" > "$BUILD_FILE"

echo "============================================"
echo "  Build #${BUILD} 完成"
echo "  deb:   ${DEB_FILE}"
echo "  dylib: ${DYLIB_FILE}"
echo "  Next:  #$((BUILD + 1))"
echo "============================================"
