.pragma library

// Exposé layout. Windows keep the arrangement they have on the desktop: the
// whole workspace is zoomed out to fit the stage, so a tiled workspace looks
// like itself, smaller. Windows that overlap (floating ones, stacked ones) are
// first pushed apart until every one is fully visible.
//
//   wins    [{ addr, rx, ry, rw, rh }]   window boxes, overlay coordinates
//   screen  { w, h }                     the overlay's own size
//   area    { x, y, w, h }               where the windows may go
//   gap     extra space between windows, in stage pixels
//
// Returns { addr: { x, y, w, h } }.
function natural(wins, screen, area, gap) {
  var out = {}
  var n = wins.length
  if (n === 0 || area.w <= 0 || area.h <= 0) return out

  var r = []
  for (var i = 0; i < n; i++)
    r.push({ addr: wins[i].addr, x: wins[i].rx, y: wins[i].ry, w: Math.max(1, wins[i].rw), h: Math.max(1, wins[i].rh) })

  // A wide stage has more room sideways, so prefer pushing sideways.
  var bias = screen.h / Math.max(1, screen.w)
  for (var iter = 0; iter < 160; iter++) {
    var moved = false
    for (var a = 0; a < n; a++) {
      for (var b = a + 1; b < n; b++) {
        var p = r[a], q = r[b]
        var ox = Math.min(p.x + p.w, q.x + q.w) - Math.max(p.x, q.x)
        var oy = Math.min(p.y + p.h, q.y + q.h) - Math.max(p.y, q.y)
        if (ox <= 1 || oy <= 1) continue
        moved = true
        if (ox * bias <= oy) {
          var dx = (q.x + q.w / 2 >= p.x + p.w / 2) ? 1 : -1
          p.x -= dx * (ox / 2 + 1)
          q.x += dx * (ox / 2 + 1)
        } else {
          var dy = (q.y + q.h / 2 >= p.y + p.h / 2) ? 1 : -1
          p.y -= dy * (oy / 2 + 1)
          q.y += dy * (oy / 2 + 1)
        }
      }
    }
    if (!moved) break
  }

  // Zoom out around the screen itself, so a lone window stays where it was.
  var minX = 0, minY = 0, maxX = screen.w, maxY = screen.h
  for (var k = 0; k < n; k++) {
    minX = Math.min(minX, r[k].x)
    minY = Math.min(minY, r[k].y)
    maxX = Math.max(maxX, r[k].x + r[k].w)
    maxY = Math.max(maxY, r[k].y + r[k].h)
  }
  var bw = maxX - minX, bh = maxY - minY
  var s = Math.min(area.w / bw, area.h / bh, 1)
  var ox0 = area.x + (area.w - bw * s) / 2
  var oy0 = area.y + (area.h - bh * s) / 2

  // One scale for both directions of a window, or its text is squeezed; and
  // whole pixels for where it comes to rest.
  for (var m = 0; m < n; m++) {
    var cw = r[m].w * s, ch = r[m].h * s
    var k = Math.max(0.02, Math.min((cw - gap) / r[m].w, (ch - gap) / r[m].h))
    var w = r[m].w * k, h = r[m].h * k
    out[r[m].addr] = {
      x: Math.round(ox0 + (r[m].x - minX) * s + (cw - w) / 2),
      y: Math.round(oy0 + (r[m].y - minY) * s + (ch - h) / 2),
      w: w,
      h: h
    }
  }
  return out
}

// One step of a critically damped spring. Returns [position, velocity].
function spring(x, v, target, omega, dt) {
  var steps = Math.max(1, Math.ceil(dt / 0.004))
  var h = dt / steps
  for (var i = 0; i < steps; i++) {
    var acc = -omega * omega * (x - target) - 2 * omega * v
    v += acc * h
    x += v * h
  }
  return [x, v]
}

// Finger travel past the end moves less and less.
function rubber(p) {
  if (p > 1) return 1 + (1 - 1 / ((p - 1) * 4 + 1)) * 0.06
  if (p < 0) return 0
  return p
}
