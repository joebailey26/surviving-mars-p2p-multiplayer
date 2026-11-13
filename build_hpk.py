"""Build multiplayer.hpk (Haemimont 'BPUL' pack, uncompressed entries) from ./src.

Usage:  python build_hpk.py            -> writes multiplayer.hpk next to this script
Layout mirrors the game's own DLC packs: file data, then directory blobs, then
the fragment table. Fragment 1 is the root directory; indices are 1-based.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
OUT = os.path.join(HERE, "multiplayer.hpk")


def build(src, out):
    # fragment list: index 0 (fragment #1) is reserved for the root directory
    frags = [None]
    blobs = {}          # fragment index -> bytes

    def add_dir(path):
        """Returns the directory listing bytes for `path`, registering children."""
        entries = []
        names = sorted(os.listdir(path), key=lambda n: n.lower())
        # Depth-first numbering, as in the stock packs: a directory's whole
        # subtree takes the fragment indices right after its own. The engine
        # relies on this when listing a folder (a breadth-first pack mounts,
        # but its Code/ folder lists as empty).
        for name in names:
            full = os.path.join(path, name)
            is_dir = os.path.isdir(full)
            frags.append(None)
            idx = len(frags) - 1
            if is_dir:
                blobs[idx] = ("dir", add_dir(full))
            else:
                with open(full, "rb") as f:
                    blobs[idx] = ("file", f.read())
            nm = name.encode("latin1")
            entries.append(struct.pack("<IIH", idx + 1, 1 if is_dir else 0, len(nm)) + nm)
        return b"".join(entries)

    blobs[0] = ("dir", add_dir(src))

    body = bytearray()
    offset = 36
    # files first, directories after (as in the stock packs)
    for kind in ("file", "dir"):
        for idx in sorted(blobs):
            k, data = blobs[idx]
            if k != kind:
                continue
            frags[idx] = (offset, len(data))
            body += data
            offset += len(data)

    table = b"".join(struct.pack("<II", o, l) for (o, l) in frags)
    header = b"BPUL" + struct.pack("<8I", 36, 1, 0xFFFFFFFF, 0, 0, 1, offset, len(table))
    with open(out, "wb") as f:
        f.write(header)
        f.write(body)
        f.write(table)
    return len(frags)


if __name__ == "__main__":
    n = build(SRC, OUT)
    print("wrote %s (%d bytes, %d entries)" % (OUT, os.path.getsize(OUT), n))
