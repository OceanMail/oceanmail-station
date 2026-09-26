"""Conservative S3a policy: config edits need a separate reviewed policy update.

Native exception candidates are bound to whole-file context. Rust/shell candidate
matching can reject strings/comments conservatively; it never grants exemptions.
This first policy does not silently remap renamed files or changed exceptions.
"""

import ast
from collections import Counter
import io
from pathlib import PurePosixPath
import re
import tokenize

from diagnostics import Finding, digest, ledger, require
from git_state import GitState
from suppression_inventory import PYTHON_DIRECTIVE


def control(filename: str) -> bool:
    p = PurePosixPath(filename)
    return (
        filename.startswith(('.github/workflows/', '.cargo/'))
        or p.name
        in {
            'clippy.toml',
            '.clippy.toml',
            'deny.toml',
            'ruff.toml',
            '.ruff.toml',
            'Cargo.toml',
            'Cargo.lock',
            'rust-toolchain',
            'rust-toolchain.toml',
            'pyproject.toml',
            'setup.cfg',
            'pytest.ini',
            'tox.ini',
            '.coveragerc',
            '.shellcheckrc',
            '.gitignore',
            '.gitattributes',
        }
        or (
            filename.startswith('.quality/')
            and p.suffix in {'.json', '.toml', '.yml', '.yaml', '.txt', '.lock'}
            and not filename.startswith(('.quality/s3a-evidence/', '.quality/reports/'))
            and p.name not in {'suppressions.json', 'advisory-exceptions.json'}
        )
    )


def candidates(filename: str, source: str) -> list[Finding]:
    directives: list[str] = []
    if filename.endswith('.py'):
        tree = ast.parse(source, filename=filename)
        for token in tokenize.generate_tokens(io.StringIO(source).readline):
            if token.type == tokenize.COMMENT and PYTHON_DIRECTIVE.search(token.string):
                directives.append(token.string)
        for node in ast.walk(tree):
            if isinstance(node, (ast.Attribute, ast.Name, ast.alias)):
                name = (
                    node.attr
                    if isinstance(node, ast.Attribute)
                    else node.id
                    if isinstance(node, ast.Name)
                    else node.name
                )
                if name in {
                    'skip',
                    'skipif',
                    'skipIf',
                    'skipUnless',
                    'skipTest',
                    'xfail',
                    'expectedFailure',
                }:
                    directives.append(ast.dump(node, include_attributes=False))
    elif filename.endswith('.rs'):
        directives = [
            match.group()
            for match in re.finditer(
                r'#\s*!?\s*\[[^\]]*\b(?:allow|expect|ignore|cfg|cfg_attr)\b[^\]]*\]',
                source,
                re.S,
            )
            if re.sub(r'\s+', '', match.group()) != '#[cfg(test)]'
        ]
    elif filename.endswith('.sh'):
        directives = [
            match.group()
            for match in re.finditer(
                r'#\s*(?:shellcheck\b|nosemgrep\b)[^\n]*',
                source,
            )
        ]
    return [
        Finding(
            'native-policy',
            'directive',
            filename,
            digest({'source': source, 'directive': directive}),
        )
        for directive in directives
    ]


def tests(filename: str, source: str) -> set[str]:
    if filename.endswith('.py'):
        found: set[str] = set()

        def walk(nodes: list[ast.stmt], prefix: str = '') -> None:
            for node in nodes:
                if isinstance(node, ast.ClassDef):
                    walk(node.body, prefix + node.name + '.')
                elif isinstance(
                    node, (ast.FunctionDef, ast.AsyncFunctionDef)
                ) and node.name.startswith('test'):
                    found.add(prefix + node.name)

        walk(ast.parse(source, filename=filename).body)
        return found
    if filename.endswith('.rs'):
        return set(
            re.findall(
                r'#\[\s*(?:[A-Za-z_][\w]*::)*test\s*\]'
                r'(?:\s|#\[[^\]]*\]|//[^\n]*(?:\n|$)|/\*[\s\S]*?\*/)*'
                r'(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)',
                source,
            )
        )
    return set()


def verify(state: GitState) -> None:
    state.require_clean()
    old_files, new_files = state.tracked(state.base), state.tracked(state.head)
    for filename in sorted(set(old_files) | set(new_files)):
        if control(filename):
            require(
                filename in old_files and filename in new_files,
                'control file added/removed: ' + filename,
            )
            require(
                old_files[filename] == new_files[filename]
                and state.read(state.base, filename)
                == state.read(state.head, filename),
                'control file changed: ' + filename,
            )
    owned = ('.rs', '.py', '.sh')
    for filename, mode in new_files.items():
        if not filename.endswith(owned):
            require(
                mode != '100755'
                and not filename.endswith(
                    ('.bash', '.zsh', '.ksh', '.fish', '.pyw', '.ps1')
                )
                and not state.has_shebang(state.head, filename),
                'unscanned executable/script requires scope policy: ' + filename,
            )
    old_sources = {p for p in old_files if p.endswith(owned)}
    new_sources = {p for p in new_files if p.endswith(owned)}
    require(
        old_sources <= new_sources, 'owned source removed/renamed; review scope policy'
    )
    actual: list[Finding] = []
    for filename in sorted(new_sources):
        source = state.read(state.head, filename)
        actual.extend(candidates(filename, source))
        if filename in old_sources:
            require(
                tests(filename, state.read(state.base, filename))
                <= tests(filename, source),
                'test identities removed/renamed: ' + filename,
            )
    from diagnostics import compare

    trusted = ledger(state.read(state.base, '.quality/suppressions.json'))
    proposed = ledger(state.read(state.head, '.quality/suppressions.json'))
    _ = compare([], trusted, proposed)
    accepted = Counter(
        entry.finding for entry in proposed if entry.finding.tool == 'native-policy'
    )
    require(
        Counter(actual) == accepted,
        'native policy directives differ from reviewed ledger/context',
    )
