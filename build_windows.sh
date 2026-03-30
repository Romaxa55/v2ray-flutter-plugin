#!/bin/bash
# Build libv2ray.dll for Windows (x64 and ARM64) on macOS
# Requires: brew install go mingw-w64

set -e

echo "🔧 Building libv2ray for Windows..."

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "❌ Go not found. Install with: brew install go"
    exit 1
fi

# Check if MinGW is installed
if ! command -v x86_64-w64-mingw32-gcc &> /dev/null; then
    echo "❌ MinGW-w64 not found. Install with: brew install mingw-w64"
    exit 1
fi

# Create output directories
mkdir -p libs/windows/x64
mkdir -p libs/windows/arm64

# Build for Windows x64
echo "📦 Building for Windows x64..."
CGO_ENABLED=1 GOOS=windows GOARCH=amd64 \
  CC=x86_64-w64-mingw32-gcc \
  go build -buildmode=c-shared \
  -o libs/windows/x64/libv2ray.dll \
  github.com/v2fly/AndroidLibV2rayLite || {
    echo "⚠️  Direct build failed, trying alternative approach..."
    echo "   You may need to build on Windows or use GitHub Actions"
    echo "   For now, creating placeholder file..."
    touch libs/windows/x64/libv2ray.dll.placeholder
}

echo "✅ x64 build complete (or placeholder created)"

# Build for Windows ARM64 (may not work on all systems)
echo "📦 Attempting Windows ARM64 build..."
if command -v aarch64-w64-mingw32-gcc &> /dev/null; then
    CGO_ENABLED=1 GOOS=windows GOARCH=arm64 \
      CC=aarch64-w64-mingw32-gcc \
      go build -buildmode=c-shared \
      -o libs/windows/arm64/libv2ray.dll \
      github.com/v2fly/AndroidLibV2rayLite || {
        echo "⚠️  ARM64 build failed, creating placeholder..."
        touch libs/windows/arm64/libv2ray.dll.placeholder
    }
else
    echo "⚠️  ARM64 compiler not found, creating placeholder..."
    touch libs/windows/arm64/libv2ray.dll.placeholder
fi

echo "✅ Build script complete!"
echo ""
echo "📝 Note: If placeholders were created, you'll need to:"
echo "   1. Build on actual Windows machine, OR"
echo "   2. Use GitHub Actions with Windows runner, OR"
echo "   3. Use pre-built v2ray-core.exe instead of DLL"
echo ""
ls -lh libs/windows/*/libv2ray.dll* 2>/dev/null || echo "No files created yet"



