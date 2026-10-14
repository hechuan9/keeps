#!/usr/bin/env python3
"""Export a private native runtime from a tested Keeps image; Docker is build-time only."""
import argparse
import json
from pathlib import Path
import subprocess
import tarfile

COLLECT = r'''
import glob,json,os,shutil,subprocess,sys,tarfile
names=['keeps-server','keeps-render','keeps-inspect','exiftool','perl','heif-convert','dcraw_emu','convert','identify','ffmpeg','ffprobe','timeout','prlimit']
programs={n:os.path.realpath(shutil.which(n)) for n in names}
files=set(programs.values())
libraries={}
roots=['/etc/ImageMagick-7','/usr/share/perl5','/usr/share/perl/5.40.1','/usr/lib/x86_64-linux-gnu/perl/5.40.1','/usr/lib/x86_64-linux-gnu/perl5/5.40','/usr/share/doc']
roots+=glob.glob('/usr/lib/x86_64-linux-gnu/ImageMagick-*')+glob.glob('/usr/lib/x86_64-linux-gnu/libheif')
for root in roots:
 for directory,_,names in os.walk(root):
  for name in names:
   path=os.path.join(directory,name)
   if os.path.isfile(path): files.add(path)
elfs=[]
for path in files:
 with open(path,'rb') as f:
  if f.read(4)==b'\x7fELF':elfs.append(path)
for path in elfs:
 p=subprocess.run(['ldd',path],capture_output=True,text=True)
 if 'not found' in p.stdout:raise RuntimeError(p.stdout)
 for line in p.stdout.splitlines():
  for word in line.split():
   if word.startswith('/') and os.path.isfile(word):
    # Dereference aliases into the library search directory, including the loader.
    libraries['/usr/lib/x86_64-linux-gnu/'+os.path.basename(word)]=word
loader='/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2'
files.add(loader)
with tarfile.open(fileobj=sys.stdout.buffer,mode='w|',dereference=True) as archive:
 for path in sorted(files):archive.add(path,arcname='runtime'+path,recursive=False)
 for target,path in sorted(libraries.items()):archive.add(path,arcname='runtime'+target,recursive=False)
 import io
 data=json.dumps({'programs':programs,'loader':loader,'files':len(files)}).encode()
 info=tarfile.TarInfo('runtime-manifest.json');info.size=len(data);info.mode=0o644
 archive.addfile(info,io.BytesIO(data))
'''

def wrappers(payload):
    manifest = json.loads((payload / 'runtime-manifest.json').read_text())
    bindir = payload / 'bin'
    bindir.mkdir(exist_ok=True)
    common = '''#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runtime="$base/runtime"
export PATH="$base/bin:$PATH"
export PERL5LIB="$runtime/usr/share/perl5:$runtime/usr/share/perl/5.40.1:$runtime/usr/lib/x86_64-linux-gnu/perl/5.40.1:$runtime/usr/lib/x86_64-linux-gnu/perl5/5.40"
export MAGICK_CONFIGURE_PATH="$runtime/etc/ImageMagick-7"
export MAGICK_CODER_MODULE_PATH="$runtime/usr/lib/x86_64-linux-gnu/ImageMagick-7.1.1/modules-Q16/coders"
export MAGICK_FILTER_MODULE_PATH="$runtime/usr/lib/x86_64-linux-gnu/ImageMagick-7.1.1/modules-Q16/filters"
export LIBHEIF_PLUGIN_PATH="$runtime/usr/lib/x86_64-linux-gnu/libheif/plugins"
'''
    for name, program in manifest['programs'].items():
        target = '"$runtime' + program + '"'
        if name == 'exiftool':
            target = '"$runtime' + manifest['programs']['perl'] + '" ' + target
        elif name in ('convert', 'identify'):
            target += ' ' + name
        command = 'exec "$runtime' + manifest['loader'] + '" --library-path "$runtime/usr/lib/x86_64-linux-gnu" ' + target + ' "$@"\n'
        path = bindir / name
        path.write_text(common + command)
        path.chmod(0o755)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--docker', default='docker')
    p.add_argument('--image', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    archive = args.output / 'runtime.tar'
    # A disposable builder executes only the collector; it mounts no host data.
    with archive.open('wb') as stream:
        subprocess.run([args.docker,'run','--rm','--network','none','--cpuset-cpus','0-1','--memory','2g','-i','--entrypoint','python3',args.image,'-'],input=COLLECT.encode(),stdout=stream,check=True)
    with tarfile.open(archive) as tar:
        # The collector emits only regular files from the explicitly selected image.
        for member in tar.getmembers():
            path=Path(member.name)
            if path.is_absolute() or '..' in path.parts or not member.isfile():
                raise ValueError('invalid runtime member: '+member.name)
        tar.extractall(args.output)
    archive.unlink()
    wrappers(args.output)
    print(json.dumps({'payload':str(args.output),'bytes':sum(p.stat().st_size for p in args.output.rglob('*') if p.is_file())}))

if __name__ == '__main__':
    main()
