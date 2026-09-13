// Snap the spine to the nearest face edge.
const SPINE = 14;

function snap(x, width) {
  if (x < 40) return 0;
  if (x > width - 40) return width;
  return x;
}

module.exports = { SPINE, snap };
