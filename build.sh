#!/usr/bin/env bash
# 一条命令出 ipa。首次先 brew install xcodegen
# 用法: ./build.sh            出未签名 ipa（自签工具用）
#       ./build.sh <TeamID>   出已签名 ipa（需本机有该 Team 的证书）
set -euo pipefail
cd "$(dirname "$0")"

TEAM="${1:-}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 xcodegen，执行: brew install xcodegen"
  exit 1
fi

echo "==> 生成工程"
xcodegen generate

rm -rf build out

if [ -n "$TEAM" ]; then
  echo "==> 签名构建 (Team: $TEAM)"
  xcodebuild \
    -project AnHongJiang.xcodeproj \
    -scheme AnHongJiang \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    build
else
  echo "==> 未签名构建"
  xcodebuild \
    -project AnHongJiang.xcodeproj \
    -scheme AnHongJiang \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build
fi

APP="build/Build/Products/Release-iphoneos/AnHongJiang.app"
mkdir -p out/Payload
cp -R "$APP" out/Payload/
(cd out && zip -qry AnHongJiang.ipa Payload)

echo "==> 完成"
ls -lh out/AnHongJiang.ipa
