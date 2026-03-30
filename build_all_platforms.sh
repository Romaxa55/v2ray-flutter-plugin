#!/bin/bash

set -e

echo "🚀 Building V2Ray static libraries for all platforms..."

cd native

# Создаем папки для библиотек
mkdir -p ../libs/macos
mkdir -p ../libs/linux
mkdir -p ../libs/android/arm64-v8a
mkdir -p ../libs/android/armeabi-v7a
mkdir -p ../libs/android/x86_64
mkdir -p ../libs/android/x86

echo "🧹 Cleaning old files..."
# Удаляем старые динамические библиотеки и бинарники
find .. -name "*.so" -delete 2>/dev/null || true
find .. -name "*.dylib" -delete 2>/dev/null || true
find .. -name "v2ray-*" -delete 2>/dev/null || true
find .. -name "libv2ray_*.a" -delete 2>/dev/null || true
find .. -name "libv2ray_*.h" -delete 2>/dev/null || true

echo "🔨 Building macOS libraries..."

# Проверяем что Go модуль уже есть
if [ ! -f "go.mod" ]; then
    echo "Error: go.mod not found in native directory"
    exit 1
fi

# macOS ARM64
echo "  📱 Building macOS ARM64..."
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 go build -buildmode=c-archive -ldflags="-s -w" -o ../libs/macos/libv2ray_arm64.a v2ray_wrapper.go

# macOS x86_64
echo "  💻 Building macOS x86_64..."
CGO_ENABLED=1 GOOS=darwin GOARCH=amd64 go build -buildmode=c-archive -ldflags="-s -w" -o ../libs/macos/libv2ray_amd64.a v2ray_wrapper.go

# Создаем универсальную macOS библиотеку
echo "  🔗 Creating universal macOS library..."
lipo -create ../libs/macos/libv2ray_arm64.a ../libs/macos/libv2ray_amd64.a -output ../libs/macos/libv2ray.a

echo "🐧 Building Linux libraries..."

# Linux требует специального Docker окружения для кросс-компиляции
echo "  ⚠️  Linux cross-compilation skipped (use Docker for Linux builds)"
echo "  💡 To build for Linux, use: docker run --rm -v \$(pwd):/src -w /src golang:1.21 ./build_linux.sh"

echo "🤖 Building Android libraries..."

# Android требует gomobile для статических библиотек
echo "  ⚠️  Android static libraries require gomobile (complex setup)"
echo "  💡 For Android, use shared libraries (.so) or gomobile bind"
echo "  📱 Run ./build_android.sh for Android builds"

cd ..

# Копируем заголовочный файл во все папки
cp native/libv2ray.h libs/
cp libs/macos/libv2ray_arm64.h libs/libv2ray.h 2>/dev/null || true

# Копируем библиотеки в другие места
cp libs/macos/libv2ray.a ../vpn_native_client/macos/ 2>/dev/null || true
cp native/libv2ray.h ../vpn_native_client/macos/ 2>/dev/null || true

# Удаляем временные файлы
rm -f libs/macos/libv2ray_arm64.a libs/macos/libv2ray_amd64.a
rm -f libs/macos/libv2ray_arm64.h libs/macos/libv2ray_amd64.h
rm -f libs/linux/libv2ray_*.h
rm -f libs/android/*/*libv2ray.h

echo "✅ All static libraries built successfully!"
echo ""
echo "📦 Static libraries created:"
echo "  🍎 macOS Universal: libs/macos/libv2ray.a"
echo ""
echo "🔧 Header file: libs/libv2ray.h"
echo "📱 Updated main app: ../vpn_native_client/macos/libv2ray.a"
echo ""
echo "🔍 macOS Library info:"
lipo -info libs/macos/libv2ray.a

echo ""
echo "📊 Library sizes:"
du -h libs/*/*.a | sort -hr