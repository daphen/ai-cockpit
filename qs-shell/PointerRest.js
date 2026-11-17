.pragma library
// Where the pointer last really moved, so a tip can tell a hand on the mouse
// from rows scrolling under a still pointer.
var x = -1, y = -1, movedAt = 0
function report(p) {
  if (p.x === x && p.y === y) return
  x = p.x; y = p.y; movedAt = Date.now()
}
