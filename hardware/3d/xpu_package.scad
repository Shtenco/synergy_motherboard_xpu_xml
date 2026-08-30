// SHTENCO XPU V1 — parametric 2.5D package model
// Units: mm.  Concept/floorplan model, not manufacturing CAD.

$fn = 48;

substrate = [65, 65, 1.5];
interposer = [55, 55, 0.6];
io_die = [10, 9, 1.2];       // 90 mm^2 baseline
compute_die = [10, 6, 1.2]; // 60 mm^2 baseline
hbm = [10, 8, 7.0];
pmem = [12, 5, 2.2];

z_interposer = substrate[2];
z_die = substrate[2] + interposer[2];

module centered_box(size, z=0, col=[0.5,0.5,0.5]) {
    color(col) translate([-size[0]/2, -size[1]/2, z]) cube(size);
}

module placed_box(pos, size, col, label="") {
    color(col) translate([pos[0], pos[1], pos[2]]) cube(size);
    if (label != "") {
        color([0.95,0.95,0.95])
            translate([pos[0] + size[0]/2, pos[1] + size[1]/2, pos[2] + size[2] + 0.03])
            linear_extrude(height=0.08)
            text(label, size=1.15, halign="center", valign="center");
    }
}

// Organic package substrate
centered_box(substrate, 0, [0.08, 0.22, 0.10]);

// Silicon interposer
centered_box(interposer, z_interposer, [0.20, 0.24, 0.28]);

// Central I/O + control die
placed_box([-5, -4.5, z_die], io_die, [0.55, 0.18, 0.18], "I/O + CTRL");

// Four 60 mm^2 compute chiplets, 2048 EML lanes each
placed_box([-5,   8, z_die], compute_die, [0.08, 0.30, 0.65], "EML C0");
placed_box([-5, -14, z_die], compute_die, [0.08, 0.30, 0.65], "EML C1");
placed_box([-17, -3, z_die], compute_die, [0.08, 0.30, 0.65], "EML C2");
placed_box([  7, -3, z_die], compute_die, [0.08, 0.30, 0.65], "EML C3");

// Four HBM3E stack placeholders
placed_box([-25, -25, z_die], hbm, [0.12, 0.12, 0.12], "HBM0");
placed_box([ 15, -25, z_die], hbm, [0.12, 0.12, 0.12], "HBM1");
placed_box([-25,  17, z_die], hbm, [0.12, 0.12, 0.12], "HBM2");
placed_box([ 15,  17, z_die], hbm, [0.12, 0.12, 0.12], "HBM3");

// Abstract persistent-state tier placeholders.
// Technology is intentionally unspecified until MRAM/ReRAM/NAND/CXL-memory is selected.
placed_box([-25, -5, z_die], pmem, [0.42, 0.18, 0.52], "PSTATE0");
placed_box([ 13, -5, z_die], pmem, [0.42, 0.18, 0.52], "PSTATE1");

// Simple host-link edge marker
color([0.8,0.65,0.1])
translate([-18, -32.5, 0.35]) cube([36, 1.2, 0.7]);

// Package legend floating above the model
color([0.95,0.95,0.95])
translate([0, 30, 2.2])
linear_extrude(height=0.08)
text("SHTENCO XPU V1 / EML DATAFLOW", size=2.0, halign="center", valign="center");
