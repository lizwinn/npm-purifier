# SPDX-License-Identifier: MIT
"""Pin and realize native npm repositories using Nix source identities."""
import argparse
import json
from pathlib import Path
import shlex
import sys
sys.path.insert(0, sys.argv[1])
import project_inputs
parser = argparse.ArgumentParser()
parser.add_argument('tools')
parser.add_argument('lock', type=Path)
parser.add_argument('state', type=Path)
parser.add_argument('bindings')
parser.add_argument('modules')
parser.add_argument('--input', action='append')
parser.add_argument('--refresh', action='store_true')
args = parser.parse_args()
previous = json.loads(args.lock.read_text()).get('projectInputs', []) if args.lock.exists() else []
references = args.input if args.input is not None else [entry['reference'] for entry in previous]
inputs = project_inputs.pin(references, previous, args.refresh)
args.state.mkdir(parents=True, exist_ok=True)
(args.state/'input-pins.json').write_text(json.dumps(inputs))
views = project_inputs.npm_views(inputs, args.state/'input-roots')
(args.state/'input-views.json').write_text(json.dumps(views, default=str))
lines = []
if inputs:
    lines = [
        'export NPM_PURIFIER_INPUT_VIEWS=' + shlex.quote(str(args.state/'input-views.json')),
        'export NPM_PURIFIER_INPUT_PINS=' + shlex.quote(str(args.state/'input-pins.json')),
        'export NPM_PURIFIER_NPM_MODULES=' + shlex.quote(args.modules),
        'export NODE_OPTIONS=' + shlex.quote('--require='+args.bindings) + ' "${NODE_OPTIONS:-}"',
    ]
# Preserve existing node options as one shell value.
if lines:
    lines[-1] = 'export NODE_OPTIONS="--require=' + args.bindings + ' ${NODE_OPTIONS:-}"'
(args.state/'input-environment').write_text('\n'.join(lines)+'\n')
