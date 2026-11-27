// Pure helpers for the charge-limit section; also run under node by tests/test_charge_limit.js.
var MIN = 50
var MAX = 100

// "key<TAB>value" lines from the read command; anything else is ignored.
function parse(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length && i < 16; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    var key = lines[i].substring(0, idx)
    if (key !== "end" && key !== "start" && key !== "saved") continue
    var value = lines[i].substring(idx + 1).trim()
    if (/^[0-9]{1,3}$/.test(value)) out[key] = parseInt(value, 10)
  }
  return out
}

// end: what the SMC enforces now. saved: what comes back at boot and on unplug.
// fullOnce: a one-time charge to 100 % is running on top of a saved limit.
// persistent: the limit the slider stands for.
function state(info) {
  var i = info || {}
  var end = Number(i.end)
  var supported = end >= 1 && end <= MAX
  var saved = Number(i.saved)
  if (!(saved >= MIN && saved <= MAX)) saved = 0
  var start = Number(i.start)
  if (!(start >= 0 && start <= MAX)) start = 0
  var fullOnce = supported && end === MAX && saved > 0 && saved < MAX
  return {
    supported: supported,
    end: supported ? end : 0,
    start: start,
    saved: saved,
    fullOnce: fullOnce,
    persistent: !supported ? 0 : (fullOnce ? saved : clamp(end))
  }
}

function clamp(value) {
  var v = Math.round(Number(value))
  if (!isFinite(v)) return MAX
  return Math.max(MIN, Math.min(MAX, v))
}

// The only arguments ever handed to m5pro-charge-limit.
function argument(value) {
  if (value === "full") return "full"
  var v = Math.round(Number(value))
  if (!isFinite(v) || v < MIN || v > MAX) return ""
  return String(v)
}

if (typeof module !== "undefined") {
  module.exports = { parse: parse, state: state, clamp: clamp, argument: argument, MIN: MIN, MAX: MAX }
}
