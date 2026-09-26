"""Run this launcher FROM THE TRUSTED BASE, never from the proposal checkout.

S4 must extract .quality from its independently selected base into an external
directory before invoking this file. This script is not a trust root by itself.
Tooling changes require separate reviewed-policy acceptance, not a self-pass.
"""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

from diagnostics import require
from git_state import GitState
from measure import write


def run_trusted(root: Path, base: str, command: str, out: Path) -> int:
    out.mkdir(parents=True, exist_ok=True)
    try:
        state = GitState(root, base)
        state.require_clean()
        old, new = state.tracked(base), state.tracked(state.head)
        code = {
            p
            for p in set(old) | set(new)
            if p.startswith('.quality/') and p.endswith(('.py', '.sh'))
        }
        require('.quality/ratchet.py' in code, 'trusted base lacks installed gate')
        for filename in sorted(code):
            require(
                filename in old
                and filename in new
                and old[filename] == new[filename]
                and state.read(base, filename) == state.read(state.head, filename),
                'gate implementation changed; independent policy review required: '
                + filename,
            )
        with tempfile.TemporaryDirectory(prefix='oceanmail-trusted-') as directory:
            trusted = Path(directory)
            for filename in sorted(code):
                if filename.endswith('.py') and filename.count('/') == 1:
                    _ = (trusted / Path(filename).name).write_text(
                        state.read(base, filename)
                    )
            # Isolated Python prevents proposal cwd, PYTHONPATH and user site imports.
            result = subprocess.run(
                [
                    sys.executable,
                    '-I',
                    '-c',
                    'import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); '
                    'import ratchet; sys.exit(ratchet.main(sys.argv[3:], root=Path(sys.argv[2])))',
                    str(trusted),
                    str(state.root),
                    command,
                    '--base',
                    base,
                    '--out',
                    str(out.resolve()),
                ],
                cwd=trusted,
                check=False,
                timeout=7200,
            )
            require(
                result.returncode in (0, 1, 2), 'trusted gate terminated unexpectedly'
            )
            state.require_clean()
            return result.returncode
    except Exception as exc:
        write(out / 'trusted-error.json', {'error': str(exc), 'exit_code': 2})
        return 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    _ = parser.add_argument('--repository', type=Path, required=True)
    _ = parser.add_argument('--base', required=True)
    _ = parser.add_argument('--out', type=Path, required=True)
    _ = parser.add_argument(
        'command',
        choices=['verify-config', 'clippy', 'shellcheck', 'python-types', 'audit'],
    )
    args = parser.parse_args()
    return run_trusted(args.repository, args.base, args.command, args.out)


if __name__ == '__main__':
    sys.exit(main())
