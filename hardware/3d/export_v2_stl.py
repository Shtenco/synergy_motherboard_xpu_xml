#!/usr/bin/env python3
"""Dependency-free ASCII STL exporter for the XPU V2 component envelopes."""
from pathlib import Path
from math import sqrt

OUT = Path(__file__).with_name("xpu_v2_package.stl")

BOXES = [
    ("substrate", -32.5, -32.5, 0.0, 65.0, 65.0, 1.5),
    ("interposer", -27.5, -27.5, 1.5, 55.0, 55.0, 0.6),
    ("io_die", -5.0, -4.5, 2.1, 10.0, 9.0, 1.2),
    ("compute_n", -5.5, 8.5, 2.1, 11.0, 7.0, 1.2),
    ("compute_s", -5.5, -15.5, 2.1, 11.0, 7.0, 1.2),
    ("compute_w", -18.0, -3.5, 2.1, 11.0, 7.0, 1.2),
    ("compute_e", 7.0, -3.5, 2.1, 11.0, 7.0, 1.2),
    ("hbm0", -25.0, -25.0, 2.1, 10.0, 8.0, 7.0),
    ("hbm1", 15.0, -25.0, 2.1, 10.0, 8.0, 7.0),
    ("hbm2", -25.0, 17.0, 2.1, 10.0, 8.0, 7.0),
    ("hbm3", 15.0, 17.0, 2.1, 10.0, 8.0, 7.0),
    ("pstate0", -25.0, -5.0, 2.1, 12.0, 5.0, 2.2),
    ("pstate1", 13.0, -5.0, 2.1, 12.0, 5.0, 2.2),
    ("noc_n", -1.0, 4.6, 2.2, 2.0, 4.0, 0.35),
    ("noc_s", -1.0, -8.6, 2.2, 2.0, 4.0, 0.35),
    ("noc_w", -8.6, -1.0, 2.2, 4.0, 2.0, 0.35),
    ("noc_e", 4.6, -1.0, 2.2, 4.0, 2.0, 0.35),
]

FACES = [
    (0, 2, 1), (0, 3, 2),
    (4, 5, 6), (4, 6, 7),
    (0, 1, 5), (0, 5, 4),
    (1, 2, 6), (1, 6, 5),
    (2, 3, 7), (2, 7, 6),
    (3, 0, 4), (3, 4, 7),
]


def vertices(x, y, z, dx, dy, dz):
    return [
        (x, y, z), (x + dx, y, z), (x + dx, y + dy, z), (x, y + dy, z),
        (x, y, z + dz), (x + dx, y, z + dz),
        (x + dx, y + dy, z + dz), (x, y + dy, z + dz),
    ]


def normal(a, b, c):
    u = tuple(b[i] - a[i] for i in range(3))
    v = tuple(c[i] - a[i] for i in range(3))
    n = (
        u[1]*v[2] - u[2]*v[1],
        u[2]*v[0] - u[0]*v[2],
        u[0]*v[1] - u[1]*v[0],
    )
    mag = sqrt(sum(q*q for q in n)) or 1.0
    return tuple(q/mag for q in n)


def main():
    lines = ["solid shtenco_xpu_v2"]
    for _, x, y, z, dx, dy, dz in BOXES:
        vs = vertices(x, y, z, dx, dy, dz)
        for face in FACES:
            a, b, c = (vs[i] for i in face)
            nx, ny, nz = normal(a, b, c)
            lines.append(f"  facet normal {nx:.6f} {ny:.6f} {nz:.6f}")
            lines.append("    outer loop")
            for p in (a, b, c):
                lines.append(f"      vertex {p[0]:.6f} {p[1]:.6f} {p[2]:.6f}")
            lines.append("    endloop")
            lines.append("  endfacet")
    lines.append("endsolid shtenco_xpu_v2")
    OUT.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"wrote {OUT} boxes={len(BOXES)} facets={len(BOXES)*len(FACES)}")


if __name__ == "__main__":
    main()
