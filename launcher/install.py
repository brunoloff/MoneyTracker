#!/usr/bin/env python3
"""Install the launcher into the current user's application menu and desktop."""
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / 'launcher/MoneyTracker.desktop'
applications = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'applications'
applications.mkdir(parents=True, exist_ok=True)
text = source.read_text()
# Support a checkout moved to another directory, including spaces in its path.
old_root = '/home/bruno/Crapbox/Repositories/MoneyTracker'
text = text.replace(old_root, str(ROOT))
text = '\n'.join('Exec="' + str(ROOT / 'launcher/run-native.sh').replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"' if line.startswith('Exec=') else line for line in text.splitlines()) + '\n'
targets = [applications / 'moneytracker.desktop']
if shutil.which('xdg-user-dir'):
    result = subprocess.run(['xdg-user-dir', 'DESKTOP'], capture_output=True, text=True, check=True)
    desktop = Path(result.stdout.strip())
else:
    desktop = Path.home() / 'Desktop'
if desktop.is_dir() and desktop != Path.home():
    targets.append(desktop / 'MoneyTracker.desktop')
for target in targets:
    target.write_text(text)
    target.chmod(0o755)
    print(f'Installed {target}')
if shutil.which('update-desktop-database'):
    subprocess.run(['update-desktop-database', str(applications)], check=False)
