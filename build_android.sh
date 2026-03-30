#!/bin/bash

set -e

echo "🤖 Building V2Ray Android shared libraries..."

cd native

# Создаем папки для Android библиотек
mkdir -p ../libs/android/arm64-v8a
mkdir -p ../libs/android/armeabi-v7a
mkdir -p ../libs/android/x86_64
mkdir -p ../libs/android/x86

echo "🧹 Cleaning old Android files..."
find ../libs/android -name "*.so" -delete 2>/dev/null || true
find ../libs/android -name "*.a" -delete 2>/dev/null || true

# Проверяем Android NDK
if [ -z "$ANDROID_NDK_HOME" ] && [ -z "$ANDROID_NDK_ROOT" ]; then
    echo "⚠️  Android NDK not found. Trying to find it..."

    # Стандартные пути для Android NDK
    if [ -d "$HOME/Library/Android/sdk/ndk" ]; then
        NDK_DIR=$(find "$HOME/Library/Android/sdk/ndk" -maxdepth 1 -type d | head -2 | tail -1)
        if [ -n "$NDK_DIR" ]; then
            export ANDROID_NDK_HOME="$NDK_DIR"
            echo "✅ Found NDK: $ANDROID_NDK_HOME"
        fi
    elif [ -d "$HOME/Android/Sdk/ndk" ]; then
        NDK_DIR=$(find "$HOME/Android/Sdk/ndk" -maxdepth 1 -type d | head -2 | tail -1)
        if [ -n "$NDK_DIR" ]; then
            export ANDROID_NDK_HOME="$NDK_DIR"
            echo "✅ Found NDK: $ANDROID_NDK_HOME"
        fi
    else
        echo "❌ Android NDK not found. Please install Android NDK and set ANDROID_NDK_HOME"
        echo "   Example: export ANDROID_NDK_HOME=/Users/\$USER/Library/Android/sdk/ndk/25.2.9519653"
        exit 1
    fi
fi

# Определяем архитектуру хоста для NDK
HOST_ARCH="darwin-x86_64"
if [ "$(uname -m)" = "arm64" ]; then
    if [ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64" ]; then
        HOST_ARCH="darwin-x86_64"
    elif [ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-arm64" ]; then
        HOST_ARCH="darwin-arm64"
    fi
fi

NDK_TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST_ARCH"

if [ ! -d "$NDK_TOOLCHAIN" ]; then
    echo "❌ NDK toolchain not found: $NDK_TOOLCHAIN"
    echo "   Available toolchains:"
    ls -la "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/" 2>/dev/null || echo "   None found"
    exit 1
fi

echo "🔨 Building Android shared libraries..."

# Android ARM64
echo "  📱 Building Android ARM64..."
export CC="$NDK_TOOLCHAIN/bin/aarch64-linux-android21-clang"
export CXX="$NDK_TOOLCHAIN/bin/aarch64-linux-android21-clang++"
CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -buildmode=c-shared -ldflags="-s -w" -o ../libs/android/arm64-v8a/libv2ray.so v2ray_wrapper.go

# Android ARMv7
echo "  📱 Building Android ARMv7..."
export CC="$NDK_TOOLCHAIN/bin/armv7a-linux-androideabi21-clang"
export CXX="$NDK_TOOLCHAIN/bin/armv7a-linux-androideabi21-clang++"
CGO_ENABLED=1 GOOS=android GOARCH=arm go build -buildmode=c-shared -ldflags="-s -w" -o ../libs/android/armeabi-v7a/libv2ray.so v2ray_wrapper.go

# Android x86_64
echo "  💻 Building Android x86_64..."
export CC="$NDK_TOOLCHAIN/bin/x86_64-linux-android21-clang"
export CXX="$NDK_TOOLCHAIN/bin/x86_64-linux-android21-clang++"
CGO_ENABLED=1 GOOS=android GOARCH=amd64 go build -buildmode=c-shared -ldflags="-s -w" -o ../libs/android/x86_64/libv2ray.so v2ray_wrapper.go

# Android x86
echo "  💻 Building Android x86..."
export CC="$NDK_TOOLCHAIN/bin/i686-linux-android21-clang"
export CXX="$NDK_TOOLCHAIN/bin/i686-linux-android21-clang++"
CGO_ENABLED=1 GOOS=android GOARCH=386 go build -buildmode=c-shared -ldflags="-s -w" -o ../libs/android/x86/libv2ray.so v2ray_wrapper.go

# Сбрасываем переменные окружения
unset CC CXX

cd ..

# Копируем заголовочный файл
cp native/libv2ray.h libs/android/

# Удаляем .h файлы из архитектурных папок (их создает c-shared)
rm -f libs/android/*/libv2ray.h

echo "✅ Android shared libraries built successfully!"
echo ""
echo "📦 Android libraries created:"
echo "  🤖 Android ARM64:   libs/android/arm64-v8a/libv2ray.so"
echo "  🤖 Android ARMv7:   libs/android/armeabi-v7a/libv2ray.so"
echo "  🤖 Android x86_64:  libs/android/x86_64/libv2ray.so"
echo "  🤖 Android x86:     libs/android/x86/libv2ray.so"
echo ""
echo "🔧 Header file: libs/android/libv2ray.h"
echo ""
echo "📊 Library sizes:"
du -h libs/android/*/*.so | sort -hr

echo ""
echo "💡 Usage in Flutter Android:"
echo "   1. Copy .so files to android/app/src/main/jniLibs/"
echo "   2. Copy libv2ray.h to android/app/src/main/cpp/"
echo "   3. Configure CMakeLists.txt to link libraries"