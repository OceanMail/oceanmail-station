#!/usr/bin/env bash
# Isolated, Station-only measurement tools; no system or product dependency edits.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
root="$PWD/.quality/tools"
mkdir -p "$root/bin" "$root/provenance"
python3.13 -m venv --clear "$root/python"
"$root/python/bin/python" -m pip install --report "$root/provenance/python-install.json" --require-hashes -r .quality/requirements.lock
"$root/python/bin/python" -m pip freeze --all >"$root/provenance/python-freeze.txt"
python3.13 -m venv --clear "$root/semgrep"
"$root/semgrep/bin/python" -m pip install --report "$root/provenance/semgrep-install.json" --require-hashes -r .quality/semgrep-requirements.lock
"$root/semgrep/bin/python" -m pip freeze --all >"$root/provenance/semgrep-freeze.txt"
rustup component add --toolchain 1.98.1 clippy rustfmt llvm-tools-preview
cargo +1.98.1 install --locked --root "$root/rust" cargo-llvm-cov --version 0.6.19
cargo +1.98.1 install --locked --root "$root/rust" cargo-audit --version 0.22.2
# Pinned official release binaries; verify upstream checksums before installing.
curl -fsSL https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_linux_amd64.tar.gz -o "$root/provenance/actionlint.tar.gz"
curl -fsSL https://github.com/rhysd/actionlint/releases/download/v1.7.7/actionlint_1.7.7_checksums.txt -o "$root/provenance/actionlint-checksums.txt"
(
    cd "$root/provenance"
    cp actionlint.tar.gz actionlint_1.7.7_linux_amd64.tar.gz
    grep ' actionlint_1.7.7_linux_amd64.tar.gz$' actionlint-checksums.txt | sha256sum -c -
)
tar -xzf "$root/provenance/actionlint.tar.gz" -C "$root/bin" actionlint
curl -fsSL https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-x86_64 -o "$root/provenance/hadolint-linux-x86_64"
curl -fsSL https://github.com/hadolint/hadolint/releases/download/v2.15.1/checksums.sha256 -o "$root/provenance/hadolint.sha256"
(
    cd "$root/provenance"
    grep -E ' [*]?hadolint-linux-x86_64$' hadolint.sha256 | sha256sum -c -
)
cp "$root/provenance/hadolint-linux-x86_64" "$root/bin/hadolint"
chmod +x "$root/bin/hadolint"
sha256sum "$root/bin/"* "$root/rust/bin/"* >"$root/provenance/binaries.sha256"
printf "export PATH=%q:%q:%q:%q:\"\$PATH\"\n" "$root/python/bin" "$root/semgrep/bin" "$root/rust/bin" "$root/bin" >"$root/env.sh"
