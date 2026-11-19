#!/usr/bin/env bash
# Build the RustGIS web app (with native NetCDF-4/HDF5 reading) and publish it as static files
# under a sub-path of an Apache site: the local demo server, or hdfeos.org.
#
#   packaging/hdfeos/deploy.sh local                 # -> /usr/local/var/www/rustgis  (http://localhost:8080/rustgis/)
#   packaging/hdfeos/deploy.sh remote                # -> https://hdfeos.org/rustgis/  (scp, as zoo/run does)
#
# Options (environment):
#   SKIP_BUILD=1       reuse dist/hdfeos from the last build
#   BUILDER=native     build without Docker: rustup's 1.99.1 toolchain with the wasm32 target
#                      (RUSTUP_BIN, or ~/.rustup/cargo/bin or ~/.cargo/bin),
#                      `trunk` on PATH (or TRUNK=path) and Homebrew's LLVM clang (the default when
#                      Docker isn't running)
#   LOCAL_WWW=dir      local target (default /usr/local/var/www/rustgis)
#   LOCAL_URL=url      URL checked after a local deploy (default http://localhost:8080/rustgis/)
#   HDFEOS_HOST        ssh login for hdfeos.org (default u40291205@home161441498.1and1-data.host)
#   HDFEOS_PATH        directory served as https://hdfeos.org/rustgis/ (default hdfeos/rustgis, under ~)
#   HDFEOS_URL         URL checked after a remote deploy (default https://hdfeos.org/rustgis/)
#
# The app is static (HTML, JS, WebAssembly); it needs no server code or special headers, only
# `application/wasm` for .wasm files, which the bundled .htaccess sets where AllowOverride permits.
set -euo pipefail

mode=${1:-}
case "$mode" in local|remote|build) ;; *) sed -n '2,20p' "$0"; exit 2 ;; esac

repo=$(cd "$(dirname "$0")/../.." && pwd)
out="$repo/dist/hdfeos"
image=rustgis-nchdf:deploy

builder=${BUILDER:-}
[ -n "$builder" ] || { docker info >/dev/null 2>&1 && builder=docker || builder=native; }

if [ "${SKIP_BUILD:-0}" != 1 ] && [ "$builder" = docker ]; then
  echo ">> building the web app in Docker (first build takes a while)"
  (cd "$repo" && DOCKER_BUILDKIT=1 docker build -t "$image" .)
  echo ">> extracting static files to $out"
  rm -rf "$out"; mkdir -p "$out"
  cid=$(docker create "$image")
  trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
  docker cp "$cid:/usr/share/nginx/html/." "$out/"
  docker rm -f "$cid" >/dev/null; trap - EXIT
elif [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo ">> building the web app natively (rustup 1.99.1 + trunk), as the Dockerfile does"
  # rustup's proxies: RUSTUP_BIN, else a self-contained install (CARGO_HOME=~/.rustup/cargo), else ~/.cargo/bin.
  rustup_bin=${RUSTUP_BIN:-}
  for d in "$HOME/.rustup/cargo/bin" "$HOME/.cargo/bin"; do [ -n "$rustup_bin" ] || { [ -x "$d/rustup" ] && rustup_bin=$d; }; done
  llvm=$(brew --prefix llvm 2>/dev/null)/bin
  trunk=${TRUNK:-$(command -v trunk || true)}
  [ -x "$rustup_bin/rustup" ] && [ -x "$llvm/clang" ] && [ -n "$trunk" ] \
    || { echo "native build needs: rustup (rustup.rs) and brew install llvm; rustup toolchain install 1.99.1 --target wasm32-unknown-unknown; trunk (or TRUNK=path)" >&2; exit 1; }
  (
    cd "$repo"
    export PATH="$rustup_bin:$PATH" RUSTUP_TOOLCHAIN=1.99.1
    export CC_wasm32_unknown_unknown="$llvm/clang" AR_wasm32_unknown_unknown="$llvm/llvm-ar"
    rm -rf dist/web
    (cd apps/rustgis-web && "$trunk" build --release --locked --public-url ./)
    cargo xtask web-pwa dist/web
  )
  echo ">> copying static files to $out"
  rm -rf "$out"; mkdir -p "$out"
  cp -R "$repo/dist/web/." "$out/"
fi
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  cat > "$out/.htaccess" <<'EOF'
AddType application/wasm .wasm
AddType application/manifest+json .webmanifest
<IfModule mod_headers.c>
  <FilesMatch "-[0-9a-f]{8,}(_bg)?\.(js|wasm)$">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </FilesMatch>
  <FilesMatch "\.(html|webmanifest)$|^sw\.js$">
    Header set Cache-Control "no-cache"
  </FilesMatch>
</IfModule>
EOF
fi
[ -f "$out/index.html" ] || { echo "no build in $out (run without SKIP_BUILD)" >&2; exit 1; }

check() {
  local url=$1 wasm
  echo ">> checking $url"
  curl -fsS -o /dev/null "$url" || { echo "index not served at $url" >&2; return 1; }
  wasm=$(cd "$out" && ls *_bg.wasm | head -1)
  curl -fsSI "$url$wasm" | grep -i '^content-type: *application/wasm' >/dev/null \
    || { echo "warning: $url$wasm is not served as application/wasm (browsers then refuse streaming compile)" >&2; return 1; }
  echo ">> OK: open $url and drag in a .nc/.h5/.he5 file"
}

case "$mode" in
  build) echo ">> built: $out" ;;
  local)
    dest=${LOCAL_WWW:-/usr/local/var/www/rustgis}
    mkdir -p "$dest"
    rsync -a --delete "$out/" "$dest/"
    check "${LOCAL_URL:-http://localhost:8080/rustgis/}"
    ;;
  remote)
    host=${HDFEOS_HOST:-u40291205@home161441498.1and1-data.host}
    path=${HDFEOS_PATH:-hdfeos/rustgis}
    # Copied whole to a staging folder, then swapped in, so the site never serves half a build
    # and old hashed files don't pile up.
    ssh "$host" "rm -rf '$path.new' && mkdir -p '$path.new'"
    scp -r -q "$out"/* "$out/.htaccess" "$host:$path.new/"
    ssh "$host" "rm -rf '$path.old' && { [ ! -e '$path' ] || mv '$path' '$path.old'; } && mv '$path.new' '$path' && rm -rf '$path.old'"
    check "${HDFEOS_URL:-https://hdfeos.org/rustgis/}"
    ;;
esac
