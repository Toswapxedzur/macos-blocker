#!/usr/bin/env python3
"""Read native package version metadata from the canonical XcodeGen spec."""
from pathlib import Path
import re
import sys
field = {'version': 'MARKETING_VERSION', 'build': 'CURRENT_PROJECT_VERSION'}[sys.argv[1]]
spec = Path(__file__).resolve().parents[2] / 'XcodeProject/project.yml'
values = re.findall(r'^\s*' + field + r':\s*"([0-9.]+)"\s*$', spec.read_text(), re.M)
if len(values) != 1:
    raise SystemExit('Expected one canonical ' + field)
print(values[0])
