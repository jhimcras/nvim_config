#!/usr/bin/env python3
"""Inspect literal local requires, including delayed calls and command strings.

This is a text scan, not a Lua parser: dynamic module names are not resolved.
External plugin dependencies are excluded. Exit 1 on cycles/layer violations.
"""
import argparse
import re
from pathlib import Path


def layer(module):
    name = module.removeprefix('nvim_config.')
    if name == 'env' or name == 'util' or name.startswith('util.'):
        return 0
    if name in {'prjroot', 'git', 'ansi_parser', 'launcher.registry', 'spinner'}:
        return 1
    if name == 'status' or name.startswith('status.') or name == 'tabline':
        return 3
    if name in {'init', 'setting', 'keymap', 'highlight', 'plugins'} or name.startswith('plugins.'):
        return 4
    return 2


def inspect(root):
    files = {}
    for path in sorted((root / 'lua').rglob('*.lua')):
        parts = list(path.relative_to(root / 'lua').with_suffix('').parts)
        if parts[-1] == 'init':
            parts.pop()
        files['.'.join(parts)] = path
    files['init'] = root / 'init.lua'
    graph = {name: set() for name in files}
    locations = {}
    # Accept require('x'), require 'x', pcall(require, 'x'), plus escaped
    # quotes used by RPC/keymap/statusline strings. Keep string contents.
    pattern = re.compile(r"\brequire\s*(?:\(\s*|,\s*)?['\"]([\w.]+)['\"]")
    for source, path in files.items():
        content = path.read_text()
        content = re.sub(r'--\[(=*)\[.*?\]\1\]', lambda m: '\n' * m[0].count('\n'), content, flags=re.S)
        for number, line in enumerate(content.splitlines(), 1):
            if line.lstrip().startswith('--'):
                continue
            line = line.replace('\\"', '"').replace("\\'", "'")
            for match in pattern.finditer(line):
                target = match[1]
                if target in files and target != source:
                    graph[source].add(target)
                    locations.setdefault((source, target), []).append(f'{path.relative_to(root)}:{number}')
    violations = []
    for source, targets in graph.items():
        for target in sorted(targets):
            src, dst = layer(source), layer(target)
            # A util facade can import util submodules; env is the only other
            # dependency allowed in L0. Infrastructure depends only on L0.
            invalid = dst > src or (src == 1 and dst != 0)
            if invalid:
                violations.append((source, target))
    # Tarjan strongly connected components report each cyclic group once.
    indices, low, stack, active, cycles = {}, {}, [], set(), []

    def visit(node):
        indices[node] = low[node] = len(indices)
        stack.append(node)
        active.add(node)
        for target in sorted(graph[node]):
            if target not in indices:
                visit(target)
                low[node] = min(low[node], low[target])
            elif target in active:
                low[node] = min(low[node], indices[target])
        if low[node] == indices[node]:
            group = []
            while True:
                member = stack.pop()
                active.remove(member)
                group.append(member)
                if member == node:
                    break
            if len(group) > 1 or node in graph[node]:
                cycles.append(sorted(group))

    for node in sorted(graph):
        if node not in indices:
            visit(node)
    print(f'{len(files)} modules, {sum(map(len, graph.values()))} local edges')
    for source, target in violations:
        print(f'LAYER L{layer(source)} -> L{layer(target)}: {source} -> {target} ({", ".join(locations[source, target])})')
    for group in cycles:
        print('CYCLE: ' + ', '.join(group))
        for source in group:
            for target in sorted(graph[source] & set(group)):
                print(f'  {source} -> {target} ({", ".join(locations[source, target])})')
    print(f'{len(violations)} layer violations, {len(cycles)} cyclic groups')
    return bool(violations or cycles)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    raise SystemExit(inspect(args.root.resolve()))
