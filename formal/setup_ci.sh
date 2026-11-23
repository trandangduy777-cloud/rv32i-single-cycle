#!/bin/sh
# Dung toolchain cho formal/run.sh tren Ubuntu 24.04 (job CI "formal-rvfi" va may moi):
#   yosys (YoWASP, ghim phien ban) + SymbiYosys (ghim SHA) + Boolector (ghim SHA, build tu ma nguon, kem CaDiCaL).
# Cai vao $PREFIX (mac dinh $HOME/.local); nho them $PREFIX/bin vao PATH. Boolector build mat khoang 10 phut (CI luu cache).
set -e
PREFIX=${PREFIX:-$HOME/.local}
SBY_SHA=b21f778333efc1e7c33fe22b56d43f87e4f759d4
BTOR_SHA=43dae91c1070e5e2633e036ebd75ffb13fe261e1
mkdir -p "$PREFIX/bin"
pip install -q --break-system-packages yowasp-yosys==0.71.0.0.post1285 2>/dev/null || pip install -q yowasp-yosys==0.71.0.0.post1285
# SymbiYosys goi yosys / yosys-smtbmc / yosys-witness: tro ve ban WASM cua YoWASP
YW=$(dirname "$(command -v yowasp-yosys)")
for t in yosys yosys-smtbmc yosys-witness; do
    printf '#!/bin/sh\nexec %s/yowasp-%s "$@"\n' "$YW" "$t" > "$PREFIX/bin/$t"; chmod +x "$PREFIX/bin/$t"
done
if [ ! -x "$PREFIX/bin/sby" ]; then
    rm -rf /tmp/sby-src; git clone -q https://github.com/YosysHQ/sby.git /tmp/sby-src
    git -C /tmp/sby-src checkout -q $SBY_SHA && make -C /tmp/sby-src install PREFIX="$PREFIX" >/dev/null
fi
if [ ! -x "$PREFIX/bin/boolector" ]; then
    rm -rf /tmp/boolector; git clone -q https://github.com/Boolector/boolector.git /tmp/boolector
    cd /tmp/boolector && git checkout -q $BTOR_SHA
    # tai phu thuoc bang git clone (khong dung tarball archive cua GitHub, vo hieu trong moi so truong co proxy)
    python3 - <<'PY'
import re
p = "contrib/setup-utils.sh"
s = open(p).read()
i = s.index("function download_github")
j = s.index("\n}\n", i) + 3
s = s[:i] + 'function download_github\n{\n  local repo="$1"\n  local version="$2"\n  local location="$3"\n  rm -rf "${location}"\n  git clone -q "https://github.com/$repo.git" "${location}"\n  git -C "${location}" checkout -q "$version"\n}\n' + s[j:]
open(p, "w").write(s)
PY
    ./contrib/setup-cadical.sh >/dev/null && ./contrib/setup-btor2tools.sh >/dev/null
    ./configure.sh >/dev/null && make -C build -j"$(nproc)" >/dev/null
    cp build/bin/boolector "$PREFIX/bin/"
fi
echo "xong: $PREFIX/bin (nho: export PATH=$PREFIX/bin:\$PATH)"
