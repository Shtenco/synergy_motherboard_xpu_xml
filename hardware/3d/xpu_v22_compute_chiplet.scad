// SHTENCO XPU V2.2 — compute-chiplet conceptual floorplan
// Units: mm. Architecture/floorplan visualization, NOT manufacturing CAD/GDS.
//
// 24 columns x 16 rows = 384 routed tiles
// 384 tiles x 8 EML lanes = 3072 EML lanes / compute chiplet
// Each tile conceptually owns 32 operand banks and local route state.

$fn = 24;

DIE_X = 11.0;
DIE_Y = 7.0;
DIE_Z = 0.45;
COLS = 24;
ROWS = 16;
LANES_PER_TILE = 8;
BANKS_PER_TILE = 32;

margin_x = 0.35;
margin_y = 0.35;
usable_x = DIE_X - 2 * margin_x;
usable_y = DIE_Y - 2 * margin_y;
pitch_x = usable_x / COLS;
pitch_y = usable_y / ROWS;

tile_x = pitch_x * 0.82;
tile_y = pitch_y * 0.78;
tile_z = 0.055;
state_y = tile_y * 0.28;

module box_at(x, y, z, sx, sy, sz, col) {
    color(col) translate([x,y,z]) cube([sx,sy,sz]);
}

// Silicon die.
box_at(0, 0, 0, DIE_X, DIE_Y, DIE_Z, [0.10,0.15,0.22]);

// Distributed 8-lane compute tiles + local operand-state stripe.
for (r = [0:ROWS-1]) {
    for (c = [0:COLS-1]) {
        x = margin_x + c*pitch_x + (pitch_x-tile_x)/2;
        y = margin_y + r*pitch_y + (pitch_y-tile_y)/2;
        // EML arithmetic region.
        box_at(x, y, DIE_Z, tile_x, tile_y-state_y, tile_z,
               ((r+c)%2==0) ? [0.05,0.36,0.72] : [0.07,0.30,0.62]);
        // 32-bank logical operand-state region.
        box_at(x, y+tile_y-state_y, DIE_Z, tile_x, state_y, tile_z*1.15,
               [0.10,0.55,0.30]);
    }
}

// Hierarchical local route spines. These are visual architectural channels,
// not literal wire bundles or claimed dimensions.
for (c = [5, 11, 17]) {
    x = margin_x + (c+0.5)*pitch_x;
    box_at(x-0.018, margin_y*0.55, DIE_Z+tile_z*1.25,
           0.036, DIE_Y-margin_y*1.1, 0.025, [0.88,0.55,0.08]);
}
for (r = [3, 7, 11]) {
    y = margin_y + (r+0.5)*pitch_y;
    box_at(margin_x*0.55, y-0.018, DIE_Z+tile_z*1.25,
           DIE_X-margin_x*1.1, 0.036, 0.025, [0.88,0.55,0.08]);
}

// Die-to-die injection/PHY edge blocks.
box_at(0.10, 0.70, DIE_Z, 0.18, DIE_Y-1.40, 0.10, [0.55,0.12,0.55]);
box_at(DIE_X-0.28, 0.70, DIE_Z, 0.18, DIE_Y-1.40, 0.10, [0.55,0.12,0.55]);

// Loader/control strip along the south edge.
box_at(0.75, 0.08, DIE_Z, DIE_X-1.50, 0.18, 0.09, [0.65,0.18,0.16]);

// Labels float above the conceptual die.
color([0.96,0.96,0.96])
translate([DIE_X/2, DIE_Y+0.20, DIE_Z+0.02])
linear_extrude(height=0.025)
text("XPU V2.2 COMPUTE CHIPLET / 3072 EML LANES", size=0.30,
     halign="center", valign="center");

color([0.96,0.96,0.96])
translate([DIE_X/2, -0.20, DIE_Z+0.02])
linear_extrude(height=0.025)
text("384 TILES x (8 LANES + 32 OPERAND BANKS)", size=0.25,
     halign="center", valign="center");
