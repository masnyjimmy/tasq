#!/bin/bash
set -euo pipefail

REPO=masnyjimmy/tasq
BIN=tasq

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2;exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

main() {
    VERSION="${1:-"${TASQ_VERSION:-latest}"}"
    INSTALL_DIR="${TASQ_INSTALL_DIR:-$HOME/.local/bin}"

    if need curl; then
        fetch() { curl -fsSL "$1" -o "$2"; }
    elif need wget; then
        fetch() { wget -qO "$2" "$1"; }
    else
        die "curl or wget is required"
    fi
    need tar || die "tar is required"

    declare os
    case "$(uname -s)" in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *) die "unsupported OS '$(uname -s)' (on windows use install.ps1 script instead)";;
    esac
    
    declare arch
    case "$(uname -m)" in
        x86_64 | amd64) arch=x86_64 ;;
        aarch | arm64) arch=aarch64 ;;
        *) die "unsupported architecture '$(uname -m)'" ;;
    esac

    if [ "$os" = macos ] && [ "$arch" = x86_64 ] &&
        [ "$(sysctl -n systcl.proc_translated @>/dev/null || echo 0)" = 1 ]; then
        arch=aarch64
    fi

    if [ "$VERSION" = latest ]; then
        if need curl; then
            url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
                "https://github.com/$REPO/releases/latest") || url=""
        else
            url=$(wget -q --spider --server-response \
                "https://github.com/$REPO/releases/latest" 2>&1 |
                awk '/^ *[Ll]ocation:/ {print $2}' | tr -d '\r' | tail -n1)
        fi
        VERSION=${url##*/}
        case "$VERSION" in
            "" | latest) die "could not determine the latest version" ;;
        esac
    fi

    case "$VERSION" in
        v*) ;;
        *) VERSION="v$VERSION" ;;
    esac
    archive="$BIN-$VERSION-$arch-$os.tar.gz"
    base="https://github.com/$REPO/releases/download/$VERSION"

    tmp=$(mktemp -d 2>/dev/null || mktemp -d -t tasq)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    say "Installing $BIN $VERSION ($arch-$os)"
    
    fetch "$base/$archive" "$tmp/$archive" || die "download failed: $base/$archive"
    fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" || die "download failed: $base/SHA256SUMS"

    expected=$(awk -v f="$archive" '$2 == f || $2 == "*" { print $1 }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || die "no checksum listed for $archive"

    declare actual
    if need sha256sum; then
        actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
    elif need shasum; then
        actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1 }')
    else
        die "sha256sum or shasum is required to verify the download"
    fi
    [ "$expected" = "$actual" ] || die "checksum mismatch for $archive"

    #=========== install ==========#

    tar -xzf "$tmp/$archive" -C "$tmp"
    [ -f "$tmp/$BIN" ] || die "archive did not contain '$BIN'"

    mkdir -p "$INSTALL_DIR"
    cp "$tmp/$BIN" "$INSTALL_DIR/.$BIN.new"
    chmod 755 "$INSTALL_DIR/.$BIN.new"
    mv -f "$INSTALL_DIR/.$BIN.new" "$INSTALL_DIR/$BIN"

    say "Installed to $INSTALL_DIR/$BIN"

    case ":$PATH" in
        *":$INSTALL_DIR"*) ;;
        *)
            say ""
            say "$INSTALL_DIR is not on your path. Add this to your shell profile:"
            say "   export PATH=\"$INSTALL_DIR:\$PATH\""
        ;;
    esac
}

main "$@"