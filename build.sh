#!/usr/bin/env bash

set -e

# Hysteria build script for Linux
# Environment variable options:
#   - HY_APP_VERSION: App version
#   - HY_APP_COMMIT: App commit hash
#   - HY_APP_PLATFORMS: Platforms to build for (e.g. "windows/amd64,linux/amd64,darwin/amd64")

export LC_ALL=C
export LC_DATE=C

GO_VERSION="1.20.10"
TEMP_DIR="./build/.tmp"
GO_DIR="$TEMP_DIR/go$GO_VERSION"

has_command() {
    local cmd="$1"
    type -P "$cmd" > /dev/null 2>&1
}

setup_go() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="armv6l" ;;
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
    esac
    
    local go_archive="go$GO_VERSION.$os-$arch.tar.gz"
    local go_url="https://golang.org/dl/$go_archive"
    
    mkdir -p "$TEMP_DIR"
    
    if [ ! -d "$GO_DIR" ]; then
        echo "Downloading Go $GO_VERSION..."
        if ! has_command curl && ! has_command wget; then
            echo 'Error: curl or wget is required to download Go.' >&2
            exit 1
        fi
        
        # Download and extract to a temporary location
        if has_command curl; then
            curl -L "$go_url" | tar -C "$TEMP_DIR" -xzf -
        else
            wget -O- "$go_url" | tar -C "$TEMP_DIR" -xzf -
        fi
        
        # Rename the extracted 'go' directory to the expected versioned name
        if [ -d "$TEMP_DIR/go" ]; then
            mv "$TEMP_DIR/go" "$GO_DIR"
        else
            echo "Error: Failed to extract Go archive" >&2
            exit 1
        fi
        
        if [ ! -d "$GO_DIR" ]; then
            echo "Error: Failed to set up Go directory" >&2
            exit 1
        fi
    fi
    
    export GOROOT="$PWD/$GO_DIR"
    export GOPATH="$PWD/$TEMP_DIR/go-build"
    export PATH="$GOROOT/bin:$PATH"
    
    mkdir -p "$GOPATH"
}

setup_go

if ! has_command git; then
    echo 'Error: git is not installed.' >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo 'Error: not in a git repository.' >&2
    exit 1
fi


platform_to_env() {
    local os="$1"
    local arch="$2"
    local env="GOOS=$os GOARCH=$arch CGO_ENABLED=0"

    case "$arch" in
    arm)
        env+=" GOARM=7 GOARCH=arm"
        ;;
    armv5)
        env+=" GOARM=5 GOARCH=arm"
        ;;
    armv6)
        env+=" GOARM=6 GOARCH=arm"
        ;;
    armv7)
        env+=" GOARM=7 GOARCH=arm"
        ;;
    mips | mipsle)
        env+=" GOMIPS="
        ;;
    mips-sf)
        env+=" GOMIPS=softfloat GOARCH=mips"
        ;;
    mipsle-sf)
        env+=" GOMIPS=softfloat GOARCH=mipsle"
        ;;
    amd64)
        env+=" GOAMD64= GOARCH=amd64"
        ;;
    amd64-avx)
        env+=" GOAMD64=v3 GOARCH=amd64"
        ;;
    esac

    echo "$env"
}

make_ldflags() {
    local ldflags="-buildid= -s -w -X 'main.appDate=$(date -u '+%F %T')'"
    if [ -n "$HY_APP_VERSION" ]; then
        ldflags="$ldflags -X 'main.appVersion=$HY_APP_VERSION'"
    else
        ldflags="$ldflags -X 'main.appVersion=$(git describe --tags --always --match 'v*')'"
    fi
    if [ -n "$HY_APP_COMMIT" ]; then
        ldflags="$ldflags -X 'main.appCommit=$HY_APP_COMMIT'"
    else
        ldflags="$ldflags -X 'main.appCommit=$(git rev-parse HEAD)'"
    fi
    echo "$ldflags"
}

build_for_platform() {
    local platform="$1"
    local ldflags="$2"

    local GOOS="${platform%/*}"
    local GOARCH="${platform#*/}"
    if [[ -z "$GOOS" || -z "$GOARCH" ]]; then
        echo "Invalid platform $platform" >&2
        return 1
    fi
    echo "Building $GOOS/$GOARCH"
    local output="build/hysteria-$GOOS-$GOARCH"
    if [[ "$GOOS" = "windows" ]]; then
        output="$output.exe"
    fi
    local envs="$(platform_to_env "$GOOS" "$GOARCH")"
    local exit_val=0
    env $envs $GOROOT/bin/go build -o "$output" -tags=gpl -ldflags "$ldflags" -trimpath ./app/cmd/ || exit_val=$?
    if [[ "$exit_val" -ne 0 ]]; then
        echo "Error: failed to build $GOOS/$GOARCH" >&2
        return $exit_val
    fi
}


if [ -z "$HY_APP_PLATFORMS" ]; then
    HY_APP_PLATFORMS="$($GOROOT/bin/go env GOOS)/$($GOROOT/bin/go env GOARCH)"
fi
platforms=(${HY_APP_PLATFORMS//,/ })
ldflags="$(make_ldflags)"

mkdir -p build
rm -rf build/*

echo "Starting build..."

for platform in "${platforms[@]}"; do
    build_for_platform "$platform" "$ldflags"
done

echo "Build complete."

ls -lh build/ | awk '{print $9, $5}'

# build android libs
targets=(
  "aarch64-linux-android21 arm64 arm64-v8a"
  "armv7a-linux-androideabi21 arm armeabi-v7a"
  "x86_64-linux-android21 amd64 x86_64"
  "i686-linux-android21 386 x86"
)

mkdir -p ./build/libs

for target in "${targets[@]}"; do
  IFS=' ' read -r ndk_target goarch abi <<< "$target"
  echo "Building for ${abi} with ${ndk_target} (${goarch})"
  CC="${NDK_HOME}/toolchains/llvm/prebuilt/darwin-x86_64/bin/${ndk_target}-clang" CGO_ENABLED=1 GOOS=android GOARCH=$goarch $GOROOT/bin/go build -o ./build/libs/$abi/libhysteria.so -trimpath -ldflags "-s -w -buildid=" -buildvcs=false ./app/cmd
  echo "Built libhysteria.so for ${abi}"
done

