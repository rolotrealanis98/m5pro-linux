// Pure helpers for the rolo.display panel. No QML in here, so node can test it.

// Fine scale stops in 1/120 (the step the fractional-scale protocol uses): 1, 1.125, 1.25, 1.33, 1.5, 1.6,
// 1.67, 1.75, 1.875, 2, 2.25, 2.5, 3.
var SCALE_STOPS = [120, 135, 150, 160, 180, 192, 200, 210, 225, 240, 270, 300, 360]
var NAME_RE = /^[A-Za-z0-9._-]{1,64}$/
var MODE_RE = /^(\d{3,5})x(\d{3,5})@(\d{1,3}(?:\.\d{1,6})?)Hz$/
var CM_RE = /^[a-z0-9]{1,16}$/

function num(value, fallback) {
  if (value === null || value === undefined || value === "" || typeof value === "boolean") return fallback
  var n = Number(value)
  return isFinite(n) ? n : fallback
}

function emptyState() {
  return {
    monitors: [],
    vrr: -1,
    autoHdr: -1,
    scaleChecksOff: false,
    xdr: { supported: false, max: 0, sdr: 0, peak: 0, nits: 0, range: 0 },
    autoBrightness: { supported: false, on: false },
    nightlight: { supported: false, on: false },
    overrides: false
  }
}

// The JSON of "display-ctl state", reduced to what the panel shows. Anything unexpected is dropped.
function parseState(raw) {
  var s = emptyState()
  var d = null
  try { d = raw ? JSON.parse(String(raw)) : null } catch (e) { d = null }
  if (!d || typeof d !== "object" || Array.isArray(d)) return s

  var list = Array.isArray(d.monitors) ? d.monitors.slice(0, 16) : []
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || typeof m !== "object" || !NAME_RE.test(String(m.name))) continue
    var w = Math.round(num(m.width, 0))
    var h = Math.round(num(m.height, 0))
    if (w <= 0 || h <= 0) continue
    var modes = []
    var rawModes = Array.isArray(m.modes) ? m.modes.slice(0, 200) : []
    for (var j = 0; j < rawModes.length; j++) {
      var id = String(rawModes[j])
      if (MODE_RE.test(id) && modes.indexOf(id) < 0) modes.push(id)
    }
    s.monitors.push({
      name: String(m.name),
      focused: m.focused === true,
      enabled: m.enabled !== false,
      builtin: m.builtin === true,
      width: w,
      height: h,
      refresh: num(m.refresh, 0),
      scale: Math.max(0.5, Math.min(4, num(m.scale, 1))),
      vrr: m.vrr === true,
      vrrCapable: m.vrrCapable !== false,
      hdrCapable: m.hdrCapable === true,
      cm: CM_RE.test(String(m.cm)) ? String(m.cm) : "",
      bitdepth: num(m.bitdepth, 8) === 10 ? 10 : 8,
      modes: modes
    })
  }

  var vrr = num(d.vrr, -1)
  s.vrr = vrr >= 0 && vrr <= 3 ? Math.round(vrr) : -1
  var autoHdr = num(d.autoHdr, -1)
  s.autoHdr = autoHdr >= 0 && autoHdr <= 9 ? Math.round(autoHdr) : -1
  s.scaleChecksOff = d.scaleChecksOff === true

  var x = d.xdr
  if (x && typeof x === "object" && x.supported === true) {
    var sdr = Math.round(num(x.sdr, 0))
    var peak = Math.round(num(x.peak, 0))
    if (sdr > 0 && peak > sdr && peak <= 10000) {
      var max = Math.round(num(x.max, 0))
      var range = Math.round(num(x.range, sdr))
      s.xdr = {
        supported: true,
        max: max > sdr && max <= peak ? max : 0,
        sdr: sdr,
        peak: peak,
        nits: Math.max(0, Math.min(peak, Math.round(num(x.nits, 0)))),
        range: range >= sdr && range <= peak ? range : sdr
      }
    }
  }
  if (d.autoBrightness && d.autoBrightness.supported === true) s.autoBrightness = { supported: true, on: d.autoBrightness.on === true }
  if (d.nightlight && d.nightlight.supported === true) s.nightlight = { supported: true, on: d.nightlight.on === true }

  var o = d.overrides
  s.overrides = !!o && typeof o === "object" && !Array.isArray(o) && Object.keys(o).length > 0
  return s
}

// The monitor the panel acts on: the focused one, as in the stock panel.
function focused(state) {
  var list = state && Array.isArray(state.monitors) ? state.monitors : []
  var first = null
  for (var i = 0; i < list.length; i++) {
    if (!list[i].enabled) continue
    if (list[i].focused) return list[i]
    if (!first) first = list[i]
  }
  return first
}

function scaleStops() { return SCALE_STOPS.slice() }

function scale120(scale) { return Math.round(num(scale, 1) * 120) }

function gcd(a, b) {
  while (b) {
    var t = a % b
    a = b
    b = t
  }
  return a
}

// True when the scale gives whole logical pixels both ways, which is what Hyprland accepts as it is.
function isClean(k, width, height) {
  k = Math.round(num(k, 0))
  var w = Math.round(num(width, 0))
  var h = Math.round(num(height, 0))
  if (k <= 0 || w <= 0 || h <= 0) return false
  var g = gcd(w * 120, h * 120)
  return k <= g && g % k === 0
}

function nearestStop(k) {
  var best = 0
  var bestDistance = Infinity
  for (var i = 0; i < SCALE_STOPS.length; i++) {
    var distance = Math.abs(SCALE_STOPS[i] - k)
    if (distance < bestDistance) {
      best = i
      bestDistance = distance
    }
  }
  return best
}

// Decimals worth showing: 2 -> 0, 1.5 -> 1, 1.25 -> 2, 1.125 -> 3, and 1.33 rather than 1.333.
function scaleDecimals(k) {
  k = Math.round(num(k, 120))
  if (k % 120 === 0) return 0
  if (k % 40 === 0) return 2
  var text = (k / 120).toFixed(3).replace(/0+$/, "")
  return Math.max(1, text.length - text.indexOf(".") - 1)
}

function looksLike(k, width, height) {
  k = Math.max(1, Math.round(num(k, 120)))
  return { width: Math.round(num(width, 0) * 120 / k), height: Math.round(num(height, 0) * 120 / k) }
}

function parseMode(id) {
  var match = MODE_RE.exec(String(id))
  if (!match) return null
  return { id: String(id), width: Number(match[1]), height: Number(match[2]), rate: Number(match[3]) }
}

function rateDecimals(rate) {
  var r = Math.round(num(rate, 0) * 100) / 100
  return Math.abs(r - Math.round(r)) < 0.05 ? 0 : 2
}

function rateKey(rate) {
  var r = Math.round(num(rate, 0) * 100) / 100
  return rateDecimals(r) === 0 ? String(Math.round(r)) : r.toFixed(2)
}

// The different resolutions a monitor lists, largest first, at most 12.
function resolutions(monitor) {
  var out = []
  var seen = {}
  var modes = monitor && Array.isArray(monitor.modes) ? monitor.modes : []
  for (var i = 0; i < modes.length; i++) {
    var mode = parseMode(modes[i])
    if (!mode) continue
    var key = mode.width + "x" + mode.height
    if (seen[key]) continue
    seen[key] = true
    out.push({ value: key, width: mode.width, height: mode.height })
  }
  out.sort(function(a, b) { return b.width * b.height - a.width * a.height || b.width - a.width })
  return out.slice(0, 12)
}

// The refresh rates listed for one resolution, fastest first, one entry per displayed rate.
function rates(monitor, width, height) {
  var out = []
  var seen = {}
  var modes = monitor && Array.isArray(monitor.modes) ? monitor.modes : []
  for (var i = 0; i < modes.length; i++) {
    var mode = parseMode(modes[i])
    if (!mode || mode.width !== width || mode.height !== height) continue
    var key = rateKey(mode.rate)
    if (seen[key]) continue
    seen[key] = true
    out.push({ id: mode.id, rate: mode.rate })
  }
  out.sort(function(a, b) { return b.rate - a.rate })
  return out.slice(0, 10)
}

// The listed mode the monitor runs now, or "" when it runs one that is not listed.
function currentMode(monitor) {
  if (!monitor) return ""
  var list = rates(monitor, monitor.width, monitor.height)
  var best = ""
  var bestDistance = 0.6
  for (var i = 0; i < list.length; i++) {
    var distance = Math.abs(list[i].rate - monitor.refresh)
    if (distance < bestDistance) {
      best = list[i].id
      bestDistance = distance
    }
  }
  return best
}

// For a change of resolution: the mode of that resolution whose rate is nearest the current one.
function modeFor(monitor, resolution) {
  var match = /^(\d+)x(\d+)$/.exec(String(resolution))
  if (!monitor || !match) return ""
  var list = rates(monitor, Number(match[1]), Number(match[2]))
  var best = ""
  var bestDistance = Infinity
  for (var i = 0; i < list.length; i++) {
    var distance = Math.abs(list[i].rate - monitor.refresh)
    if (distance < bestDistance) {
      best = list[i].id
      bestDistance = distance
    }
  }
  return best
}

// Brightness ceilings offered: the standard maximum, a few steps, the panel's peak.
function xdrStops(sdr, peak) {
  sdr = Math.round(num(sdr, 0))
  peak = Math.round(num(peak, 0))
  if (sdr <= 0 || peak <= sdr) return []
  var out = [sdr]
  var steps = [800, 1000, 1300]
  for (var i = 0; i < steps.length; i++) if (steps[i] > sdr && steps[i] < peak) out.push(steps[i])
  out.push(peak)
  return out
}

function nitsNow(percent, range) {
  return Math.round(Math.max(0, Math.min(100, num(percent, 0))) / 100 * Math.max(0, num(range, 0)))
}

function hdrMode(monitor, autoHdr) {
  if (monitor && String(monitor.cm).indexOf("hdr") === 0) return "on"
  return num(autoHdr, 0) > 0 ? "auto" : "off"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseState: parseState, focused: focused, scaleStops: scaleStops, scale120: scale120, isClean: isClean,
    nearestStop: nearestStop, scaleDecimals: scaleDecimals, looksLike: looksLike, parseMode: parseMode,
    rateDecimals: rateDecimals, resolutions: resolutions, rates: rates, currentMode: currentMode, modeFor: modeFor,
    xdrStops: xdrStops, nitsNow: nitsNow, hdrMode: hdrMode
  }
}
