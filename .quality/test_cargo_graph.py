"""Locked graph identities must retain all root-to-package paths."""

import unittest

from cargo_graph import dependency_paths
from diagnostics import ReportError, array, obj


def graph() -> dict[str, object]:
    return {
        'packages': [
            {'id': name, 'name': name, 'version': '1.0', 'source': None}
            for name in ('root', 'left', 'right', 'leaf')
        ],
        'workspace_members': ['root'],
        'resolve': {
            'nodes': [
                {'id': 'root', 'dependencies': ['left', 'right']},
                {'id': 'left', 'dependencies': ['leaf']},
                {'id': 'right', 'dependencies': ['leaf']},
                {'id': 'leaf', 'dependencies': []},
            ]
        },
    }


class CargoGraph(unittest.TestCase):
    def test_same_name_version_from_different_sources_retains_both_routes(self) -> None:
        report = graph()
        packages = array(report['packages'])
        for index, source in (
            (1, 'registry+https://example.invalid'),
            (2, 'git+https://example.invalid/fork'),
        ):
            package = obj(packages[index])
            package['name'] = 'shared'
            package['source'] = source
        routes = dependency_paths(report)[('shared', '1.0')]
        self.assertEqual(len(routes), 2)
        self.assertTrue(any('registry+' in route for route in routes))
        self.assertTrue(any('git+' in route for route in routes))

    def test_diamond_retains_both_paths(self) -> None:
        routes = dependency_paths(graph())
        self.assertEqual(len(routes[('leaf', '1.0')]), 2)
        self.assertNotEqual(*routes[('leaf', '1.0')])

    def test_unresolved_cycle_duplicate_and_partial_graph_rejected(self) -> None:
        for dependencies in (['missing'], ['root'], ['leaf', 'leaf']):
            report = graph()
            nodes = array(obj(report['resolve'])['nodes'])
            obj(nodes[1])['dependencies'] = dependencies
            with (
                self.subTest(dependencies=dependencies),
                self.assertRaises(ReportError),
            ):
                _ = dependency_paths(report)
        report = graph()
        nodes = array(obj(report['resolve'])['nodes'])
        _ = nodes.pop()
        with self.assertRaises(ReportError):
            _ = dependency_paths(report)

    def test_local_checkout_ids_do_not_change_identity(self) -> None:
        first = dependency_paths(graph())
        report = graph()
        for raw in array(report['packages']):
            item = obj(raw)
            if item['id'] == 'root':
                item['id'] = 'path+file:///different/checkout#root@1.0'
        obj(array(obj(report['resolve'])['nodes'])[0])['id'] = (
            'path+file:///different/checkout#root@1.0'
        )
        report['workspace_members'] = ['path+file:///different/checkout#root@1.0']
        self.assertEqual(first, dependency_paths(report))
