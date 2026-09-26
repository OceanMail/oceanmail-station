"""Resolve advisory identities using the complete locked Cargo metadata graph."""

import json

from diagnostics import array, obj, require, string


def dependency_paths(metadata: object) -> dict[tuple[str, str], list[str]]:
    report = obj(metadata)
    packages: dict[str, tuple[str, str]] = {}
    labels: dict[str, str] = {}
    for raw in array(report.get('packages')):
        package = obj(raw)
        identity = string(package.get('id'))
        require(identity not in packages, 'duplicate Cargo package id')
        name, version = string(package.get('name')), string(package.get('version'))
        packages[identity] = (name, version)
        source = package.get('source')
        require(source is None or isinstance(source, str), 'invalid package source')
        # Local Cargo package ids contain checkout-dependent absolute file URIs.
        # The unique name/version/source label is stable across checkout paths.
        labels[identity] = json.dumps([name, version, source], separators=(',', ':'))
    require(len(set(labels.values())) == len(labels), 'ambiguous package identities')
    graph: dict[str, list[str]] = {}
    for raw in array(obj(report.get('resolve')).get('nodes')):
        node = obj(raw)
        identity = string(node.get('id'))
        require(
            identity in packages and identity not in graph,
            'unknown/duplicate graph node',
        )
        dependencies = [string(item) for item in array(node.get('dependencies'))]
        require(
            len(set(dependencies)) == len(dependencies), 'duplicate dependency edge'
        )
        require(all(item in packages for item in dependencies), 'unresolved dependency')
        graph[identity] = sorted(dependencies)
    require(set(graph) == set(packages), 'incomplete Cargo graph')
    roots = [string(item) for item in array(report.get('workspace_members'))]
    require(
        bool(roots) and len(set(roots)) == len(roots),
        'missing/duplicate workspace roots',
    )
    require(all(root in graph for root in roots), 'missing workspace graph node')
    result: dict[tuple[str, str], list[str]] = {}
    # Cargo dev-dependency cycles can exist. Do not silently drop cyclic paths.
    # Fail closed and require explicit graph policy before accepting such a scan.
    stack: list[tuple[str, tuple[str, ...]]] = [(root, ()) for root in sorted(roots)]
    count = 0
    while stack:
        identity, ancestors = stack.pop()
        require(identity not in ancestors, 'cyclic dependency graph requires triage')
        route = (*ancestors, identity)
        count += 1
        require(count <= 100000, 'dependency path expansion exceeds bound')
        encoded = json.dumps([labels[item] for item in route], separators=(',', ':'))
        result.setdefault(packages[identity], []).append(encoded)
        stack.extend((child, route) for child in graph[identity])
    return {key: sorted(values) for key, values in result.items()}
