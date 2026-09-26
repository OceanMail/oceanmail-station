"""Pinned live Rust adapter probes; seeds ledgers only in disposable fixtures."""

from dataclasses import asdict
from datetime import timedelta
import json
from pathlib import Path
import tempfile
import sys

from adapter_runner import Scanner, scan
from cargo_graph import dependency_paths
from diagnostics import decode, digest, require
from execution_policy import utc_now
from git_state import GitState
from measure import write
from ratchet import main
from test_git_state import git


def smoke(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    outcomes: list[dict[str, object]] = []
    for kind in ('clippy', 'audit'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _ = git(root, 'init', '-q')
            _ = git(root, 'config', 'user.email', 'fixture@example.invalid')
            _ = git(root, 'config', 'user.name', 'Disposable validation fixture')
            (root / 'src').mkdir()
            (root / '.quality').mkdir()
            _ = (root / '.gitignore').write_text('/target/\n')
            manifest = (
                '[package]\nname="quality-fixture"\nversion="0.1.0"\nedition="2021"\n'
            )
            if kind == 'audit':
                manifest += '[dependencies]\ntime="=0.1.45"\n'
            _ = (root / 'Cargo.toml').write_text(manifest)
            source = (
                'fn unused() {}\nfn main() {}\n'
                if kind == 'clippy'
                else 'fn main() {}\n'
            )
            _ = (root / 'src/main.rs').write_text(source)
            setup = out / (kind + '-setup')
            setup.mkdir()
            scanner = Scanner(root, setup)
            _, code = scanner.execute('lock', ['cargo', '+1.98.1', 'generate-lockfile'])
            require(code == 0, 'fixture lock generation failed')
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'fixture source')
            initial = git(root, 'rev-parse', 'HEAD')
            _ = git(root, 'commit', '--allow-empty', '-qm', 'probe')
            findings = scan(kind, GitState(root, initial), scanner)
            require(bool(findings), 'negative fixture must produce actual findings')
            entries = [
                {
                    **asdict(f),
                    'issue': 'https://github.com/OceanMail/oceanmail-station/issues/58',
                    'reason': 'disposable fixture only',
                }
                for f in findings
            ]
            _ = (root / '.quality/suppressions.json').write_text(
                json.dumps({'entries': entries})
            )
            companion: list[dict[str, str]] = []
            if kind == 'audit':
                routes = dependency_paths(
                    decode((setup / 'cargo-metadata.stdout').read_text())
                )
                for finding in set(findings):
                    matches = [
                        (name, version, route)
                        for (name, version), paths in routes.items()
                        for route in paths
                        if digest({'package': name, 'version': version, 'path': route})
                        == finding.fingerprint
                    ]
                    require(len(matches) == 1, 'ambiguous fixture identity')
                    name, version, route = matches[0]
                    today = utc_now().date()
                    companion.append(
                        {
                            **asdict(finding),
                            'owner': 'fixture',
                            'created': today.isoformat(),
                            'expires': (today + timedelta(days=1)).isoformat(),
                            'package': name,
                            'version': version,
                            'dependency_path': route,
                        }
                    )
            _ = (root / '.quality/advisory-exceptions.json').write_text(
                json.dumps(companion)
            )
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'disposable accepted identities')
            base = git(root, 'rev-parse', 'HEAD')
            _ = git(root, 'commit', '--allow-empty', '-qm', 'unchanged proposal')
            write(
                out / (kind + '-fixture.json'),
                {
                    'base': base,
                    'head': git(root, 'rev-parse', 'HEAD'),
                    'files': {
                        name: (root / name).read_text()
                        for name in (
                            'Cargo.toml',
                            'Cargo.lock',
                            'src/main.rs',
                            '.quality/suppressions.json',
                            '.quality/advisory-exceptions.json',
                        )
                    },
                },
            )
            code = main(
                [kind, '--base', base, '--out', str(out / (kind + '-accepted'))], root
            )
            require(code == 0, kind + ' accepted fixture failed')
            outcomes.append(
                {
                    'case': kind + '-accepted',
                    'findings': len(findings),
                    'exit_code': code,
                }
            )
            if kind == 'clippy':
                _ = (root / 'src/main.rs').write_text(
                    source + 'fn another_unused() {}\n'
                )
            else:
                _ = (root / '.quality/advisory-exceptions.json').write_text('[]')
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'negative probe')
            code = main(
                [kind, '--base', base, '--out', str(out / (kind + '-negative'))], root
            )
            expected = 1 if kind == 'clippy' else 2
            require(
                code == expected, kind + ' negative fixture did not fail as expected'
            )
            outcomes.append({'case': kind + '-negative', 'exit_code': code})
            write(out / 'summary.json', outcomes)
    print('4 actual pinned Rust CLI cases passed')


if __name__ == '__main__':
    require(len(sys.argv) == 2, 'provide external evidence directory')
    smoke(Path(sys.argv[1]).resolve())
