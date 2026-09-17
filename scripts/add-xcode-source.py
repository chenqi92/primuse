#!/usr/bin/env python3
"""Register new Swift source files in the checked-in Primuse.xcodeproj.

The pbxproj is tracked and is what gets built, so a file that only exists on disk is
missing from the app. This mirrors an existing sibling: the new file joins the same
group and the same targets' Sources phases as the sibling does.

    scripts/add-xcode-source.py --sibling Primuse/Views/Foo/Existing.swift Primuse/Views/Foo/New.swift [...]
    scripts/add-xcode-source.py --check            # list source files on disk that are not registered

The sibling must live in the same directory as the new files.
"""
import argparse, hashlib, os, re, sys

PBX = 'Primuse.xcodeproj/project.pbxproj'
SOURCE_ROOTS = ['Primuse', 'PrimuseKit/Sources']
UNREGISTERED_OK = {'AppSecrets.example.swift'}


def section(text, name):
    m = re.search(r'/\* Begin %s section \*/\n(.*?)/\* End %s section \*/' % (name, name), text, re.S)
    if not m:
        sys.exit(f'missing {name} section')
    return m


def groups(text):
    out = {}
    body = section(text, 'PBXGroup').group(1)
    for m in re.finditer(r'\t\t(\w{24})(?: /\* .*? \*/)? = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \((.*?)\);(.*?)\n\t\t\};', body, re.S):
        gid, children, rest = m.groups()
        path = re.search(r'\bpath = (.+?);', rest)
        out[gid] = {'children': re.findall(r'(\w{24})', children),
                    'path': path.group(1).strip('"') if path else None}
    return out


def file_refs(text):
    out = {}
    body = section(text, 'PBXFileReference').group(1)
    for m in re.finditer(r'\t\t(\w{24}) /\* (.+?) \*/ = \{isa = PBXFileReference;(.*?)\};', body):
        rid, name, rest = m.groups()
        path = re.search(r'\bpath = (.+?);', rest)
        out[rid] = path.group(1).strip('"') if path else name
    return out


def ref_paths(text):
    g, refs = groups(text), file_refs(text)
    parent = {c: gid for gid, info in g.items() for c in info['children']}
    paths = {}
    for rid, leaf in refs.items():
        parts, cur = [leaf], parent.get(rid)
        while cur is not None:
            if g[cur]['path']:
                parts.append(g[cur]['path'])
            cur = parent.get(cur)
        paths[rid] = os.path.normpath('/'.join(reversed(parts)))
    return paths, parent


def new_id(text, seed):
    n = 0
    while True:
        candidate = hashlib.sha1(f'{seed}#{n}'.encode()).hexdigest()[:24].upper()
        if candidate not in text:
            return candidate
        n += 1


def quoted(name):
    return name if re.fullmatch(r'[A-Za-z0-9_./]+', name) else f'"{name}"'


def register(text, sibling, new_path):
    paths, parent = ref_paths(text)
    new_path, sibling = os.path.normpath(new_path), os.path.normpath(sibling)
    if new_path in paths.values():
        print(f'already registered: {new_path}')
        return text
    if os.path.dirname(new_path) != os.path.dirname(sibling):
        sys.exit(f'{new_path} and {sibling} are not in the same directory')
    if not os.path.isfile(new_path):
        sys.exit(f'no such file: {new_path}')
    sibling_refs = [rid for rid, p in paths.items() if p == sibling]
    if len(sibling_refs) != 1:
        sys.exit(f'sibling {sibling} resolves to {len(sibling_refs)} file references')
    sib_ref = sibling_refs[0]
    sib_name, name = os.path.basename(sibling), os.path.basename(new_path)

    # 1) file reference, right after the sibling's
    ref_id = new_id(text, 'ref:' + new_path)
    sib_line = re.search(r'^\t\t%s /\* .*? \*/ = \{isa = PBXFileReference;.*$' % sib_ref, text, re.M)
    ref_line = (f'\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
                f'path = {quoted(name)}; sourceTree = "<group>"; }};')
    text = text[:sib_line.end()] + '\n' + ref_line + text[sib_line.end():]

    # 2) group membership, right after the sibling's entry
    child = re.search(r'^(\t+)%s /\* %s \*/,$' % (sib_ref, re.escape(sib_name)), text, re.M)
    if not child:
        sys.exit(f'sibling {sib_name} has no group entry')
    text = text[:child.end()] + f'\n{child.group(1)}{ref_id} /* {name} */,' + text[child.end():]

    # 3) one build file per target that compiles the sibling
    build_ids = re.findall(r'^\t\t(\w{24}) /\* %s in Sources \*/ = \{isa = PBXBuildFile; fileRef = %s ' % (re.escape(sib_name), sib_ref), text, re.M)
    if not build_ids:
        sys.exit(f'sibling {sib_name} is in no Sources phase')
    for index, sib_build in enumerate(build_ids):
        build_id = new_id(text, f'build:{new_path}:{index}')
        decl = re.search(r'^\t\t%s /\* .*? in Sources \*/ = \{isa = PBXBuildFile;.*$' % sib_build, text, re.M)
        text = (text[:decl.end()] + f'\n\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; '
                f'fileRef = {ref_id} /* {name} */; }};' + text[decl.end():])
        entry = re.search(r'^(\t+)%s /\* %s in Sources \*/,$' % (sib_build, re.escape(sib_name)), text, re.M)
        if not entry:
            sys.exit(f'build file {sib_build} is in no Sources phase')
        text = text[:entry.end()] + f'\n{entry.group(1)}{build_id} /* {name} in Sources */,' + text[entry.end():]
    print(f'registered {new_path} in {len(build_ids)} target(s)')
    return text


def check(text):
    registered = set(ref_paths(text)[0].values())
    missing = []
    for root in SOURCE_ROOTS:
        for directory, _, files in os.walk(root):
            for f in files:
                if f.endswith('.swift') and f not in UNREGISTERED_OK:
                    path = os.path.normpath(os.path.join(directory, f))
                    if path not in registered:
                        missing.append(path)
    for path in sorted(missing):
        print('unregistered:', path)
    return 1 if missing else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sibling')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('files', nargs='*')
    args = parser.parse_args()
    text = open(PBX, encoding='utf-8').read()
    if args.check:
        sys.exit(check(text))
    if not args.sibling or not args.files:
        parser.error('--sibling and at least one file are required')
    before = (text.count('{'), text.count('}'), text.count('('), text.count(')'))
    for path in args.files:
        text = register(text, args.sibling, path)
    after = (text.count('{'), text.count('}'), text.count('('), text.count(')'))
    if after[0] != after[1] or after[2] != after[3] or (before[0] - before[1]) != (after[0] - after[1]):
        sys.exit('brace balance changed; not writing')
    open(PBX, 'w', encoding='utf-8').write(text)


if __name__ == '__main__':
    main()
