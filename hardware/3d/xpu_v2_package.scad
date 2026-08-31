// SHTENCO XPU V2 — DSE-aligned parametric 2.5D package model
// Units: mm. Architectural floorplan only, not manufacturing CAD/GDS/package signoff.
//
// V2 reference geometry aligns with the 4-chiplet DSE family:
//   ~77 mm^2 compute die envelope ~= 3072-lane baseline at central area assumption
//   4 HBM placements
//   central I/O/control
//   two persistent-state placeholders

$fn = 48;

memory_profile = "HBM4"; // visual label only: "HBM3E" or "HBM4"

substrate = [65, 65, 1.5];
interposer = [55, 55, 0.6];
io_die = [10, 9, 1.2];        // 90 mm^2
compute_die = [11, 7, 1.2];   // 77 mm^2 ~ DSE 3072-lane envelope
hbm = [10, 8, 7.0];
pmem = [12, 5, 2.2];
bridge = [4, 2, 0.35];

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
            text(label, size=1.05, halign="center", valign="center");
    }
}

module noc_bridge(x, y, rot=0) {
    color([0.75,0.45,0.08])
        translate([x,y,z_die+0.10])
        rotate([0,0,rot])
        translate([-bridge[0]/2,-bridge[1]/2,0])
        cube(bridge);
}

centered_box(substrate, 0, [0.08, 0.22, 0.10]);
centered_box(interposer, z_interposer, [0.20, 0.24, 0.28]);

placed_box([-5, -4.5, z_die], io_die, [0.55, 0.18, 0.18], "I/O + CTRL");

placed_box([-5.5,   8.5, z_die], compute_die, [0.08, 0.30, 0.65], "EML C0");
placed_box([-5.5, -15.5, z_die], compute_die, [0.08, 0.30, 0.65], "EML C1");
placed_box([-18.0, -3.5, z_die], compute_die, [0.08, 0.30, 0.65], "EML C2");
placed_box([  7.0, -3.5, z_die], compute_die, [0.08, 0.30, 0.65], "EML C3");

noc_bridge(0, 6.6, 90);
noc_bridge(0,-6.6, 90);
noc_bridge(-6.6,0,0);
noc_bridge( 6.6,0,0);

placed_box([-25, -25, z_die], hbm, [0.12, 0.12, 0.12], str(memory_profile, "0"));
placed_box([ 15, -25, z_die], hbm, [0.12, 0.12, 0.12], str(memory_profile, "1"));
placed_box([-25,  17, z_die], hbm, [0.12, 0.12, 0.12], str(memory_profile, "2"));
placed_box([ 15,  17, z_die], hbm, [0.12, 0.12, 0.12], str(memory_profile, "3"));

placed_box([-25, -5, z_die], pmem, [0.42, 0.18, 0.52], "PSTATE0");
placed_box([ 13, -5, z_die], pmem, [0.42, 0.18, 0.52], "PSTATE1");

color([0.8,0.65,0.1])
translate([-18, -32.5, 0.35]) cube([36, 1.2, 0.7]);

color([0.95,0.95,0.95])
translate([0, 30, 2.2])
linear_extrude(height=0.08)
text("SHTENCO XPU V2 / EML DATAFLOW", size=1.8, halign="center", valign="center");
