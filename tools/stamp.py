"""Sets sw.js VERSION to a hash of the app shell so each publish with real changes ships as a new version."""
import hashlib, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent
sw = root / 'sw.js'
src = sw.read_text()
files = re.search(r"const FILES = \[(.*?)\];", src, re.S).group(1)
names = [n for n in re.findall(r"'([^']+)'", files) if n != './']
h = hashlib.sha256()
for n in names:
    h.update(n.encode()); h.update((root / n).read_bytes())
h.update(re.sub(r"const VERSION = '[^']*';", '', src).encode())
version = h.hexdigest()[:12]
sw.write_text(re.sub(r"const VERSION = '[^']*';", f"const VERSION = '{version}';", src, count=1))
print(version)
