#!/usr/bin/env python3
"""Check the neutral contract closure, or the full agent migration gate.

The full-agent gate deliberately reports remaining legacy dependencies. Do not
replace it with the narrower contract check when assessing migration completion.
"""
import argparse
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
IMPORT = re.compile(r'@import\("([^"\n]+)"\)')
FORBIDDEN = re.compile(
    r'\b[A-Za-z0-9_]*(?:credential|oauth|subscription|billing|account|vendor|team|upgrade)[A-Za-z0-9_]*\b',
    re.IGNORECASE,
)



def production_source(text: str) -> str:
    # Remove test blocks before tracing imports. Test fixtures are not runtime
    # dependencies, and may intentionally exercise compatibility behavior.
    tokens = re.finditer(r'//[^\n]*|"(?:\\.|[^"\\])*"|\\\\[^\n]*|\btest\b|[{}]', text)
    output = list(text)
    waiting = False
    depth = 0
    start = None
    for token in tokens:
        value = token.group()
        if value == 'test' and depth == 0:
            waiting = True
            start = token.start()
        elif waiting and value == '{':
            depth = 1
            waiting = False
        elif depth and value == '{':
            depth += 1
        elif depth and value == '}':
            depth -= 1
            if depth == 0:
                for index in range(start, token.end()):
                    if output[index] != '\n':
                        output[index] = ' '
                start = None
    return ''.join(output)


def audit(whole_agent: bool) -> list[str]:
    roots = [ROOT / 'src/core/agent/model_provider.zig',
             ROOT / 'src/core/agent/runtime/model_step.zig']
    if whole_agent:
        roots = [ROOT / 'src/core/agent/agent_runtime.zig']
    pending = roots[:]
    seen = set()
    failures = set()
    while pending:
        path = pending.pop().resolve()
        if path in seen:
            continue
        seen.add(path)
        text = production_source(path.read_text())
        relative = path.relative_to(ROOT).as_posix()
        # Ignore prose comments, but do inspect declarations and callback types.
        code = re.sub(r'//[^\n]*', '', text)
        for match in FORBIDDEN.finditer(code):
            failures.add(f'{relative}: forbidden concept {match.group()}')
        for target in IMPORT.findall(text):
            if not target.endswith('.zig'):
                continue
            dependency = (path.parent / target).resolve()
            dep_relative = dependency.relative_to(ROOT).as_posix()
            if ('/auth/' in dep_relative or
                    dep_relative.endswith('/stream_provider.zig') or
                    dep_relative.endswith('/provider_set.zig') or
                    dep_relative == 'src/core/gateway/model_catalog.zig' or
                    dep_relative == 'src/core/config/model_provider.zig'):
                failures.add(f'{relative}: forbidden dependency {dep_relative}')
                continue
            pending.append(dependency)
    return sorted(failures)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--whole-agent', action='store_true',
                        help='Require the entire existing agent dependency closure to be neutral')
    args = parser.parse_args()
    failures = audit(args.whole_agent)
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        print(f'{len(failures)} boundary violations', file=sys.stderr)
        return 1
    print('model-provider boundary passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
