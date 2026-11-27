const assert = require("assert")
const X = require("../DisplayModel.js")

// What display-ctl prints on the J716s.
const real = '{"monitors":[{"name":"eDP-2","focused":true,"enabled":true,"builtin":true,"width":3456,"height":2234,"refresh":120.00000,"scale":2,"transform":0,"vrr":true,"vrrCapable":true,"hdrCapable":true,"cm":"srgb","bitdepth":10,"modes":["3456x2234@120.00Hz"]}],"vrr":1,"autoHdr":1,"scaleChecksOff":false,"xdr":{"supported":true,"max":0,"sdr":600,"peak":1600,"nits":312,"range":600},"autoBrightness":{"supported":true,"on":true},"nightlight":{"supported":true,"on":false},"overrides":{}}'
let s = X.parseState(real)
assert.strictEqual(s.monitors.length, 1)
let m = X.focused(s)
assert.deepStrictEqual([m.name, m.width, m.height, m.scale, m.vrrCapable, m.hdrCapable, m.bitdepth], ["eDP-2", 3456, 2234, 2, true, true, 10])
assert.deepStrictEqual([s.vrr, s.autoHdr, s.overrides, s.xdr.range, s.autoBrightness.on, s.nightlight.on], [1, 1, false, 600, true, false])
assert.strictEqual(X.currentMode(m), "3456x2234@120.00Hz")
assert.strictEqual(X.hdrMode(m, s.autoHdr), "auto")
assert.strictEqual(X.hdrMode(m, 0), "off")
assert.strictEqual(X.hdrMode({ cm: "hdredid" }, 0), "on")

// Garbage and markup never reach the panel.
for (const bad of ["", "nope", "[]", "null", "42", '{"monitors":7}']) assert.strictEqual(X.parseState(bad).monitors.length, 0)
s = X.parseState(JSON.stringify({
  monitors: [
    { name: "<img src=x>", width: 100, height: 100 },
    { name: "DP-1", width: "x", height: 100 },
    { name: "DP-2", width: 2560, height: 1440, refresh: 59.951, scale: 99, cm: "<b>", modes: ["2560x1440@59.95Hz", "<img>", "2560x1440@59.95Hz", "1920x1080@60.00Hz", 5] }
  ],
  vrr: 7, autoHdr: "x", xdr: { supported: true, sdr: 600, peak: 500 }, overrides: { vrr: 0 }
}))
assert.strictEqual(s.monitors.length, 1)
assert.deepStrictEqual(s.monitors[0].modes, ["2560x1440@59.95Hz", "1920x1080@60.00Hz"])
assert.deepStrictEqual([s.monitors[0].scale, s.monitors[0].cm, s.monitors[0].hdrCapable, s.monitors[0].vrrCapable], [4, "", false, true])
assert.deepStrictEqual([s.vrr, s.autoHdr, s.xdr.supported, s.overrides], [-1, -1, false, true])
assert.strictEqual(X.focused(s).name, "DP-2")
assert.strictEqual(X.focused(X.parseState("")), null)

// Scales: the notched panel only has 1x and 2x as exact ones.
assert.strictEqual(X.isClean(240, 3456, 2234), true)
assert.strictEqual(X.isClean(120, 3456, 2234), true)
for (const k of [135, 150, 160, 180, 192, 200, 210, 225, 270, 300, 360]) assert.strictEqual(X.isClean(k, 3456, 2234), false, String(k))
assert.strictEqual(X.isClean(180, 3840, 2160), true)
assert.strictEqual(X.isClean(0, 3840, 2160), false)
assert.strictEqual(X.scale120(1.3333333), 160)
assert.strictEqual(X.scaleStops()[X.nearestStop(240)], 240)
assert.strictEqual(X.scaleStops()[X.nearestStop(185)], 180)
assert.strictEqual(X.scaleStops()[X.nearestStop(480)], 360)
assert.deepStrictEqual([120, 180, 150, 135, 160, 200, 192, 225].map(X.scaleDecimals), [0, 1, 2, 3, 2, 2, 1, 3])
assert.deepStrictEqual(X.looksLike(240, 3456, 2234), { width: 1728, height: 1117 })
assert.deepStrictEqual(X.looksLike(180, 3456, 2234), { width: 2304, height: 1489 })

// Modes.
assert.deepStrictEqual(X.parseMode("3456x2234@120.00Hz"), { id: "3456x2234@120.00Hz", width: 3456, height: 2234, rate: 120 })
assert.strictEqual(X.parseMode("3456x2234@120"), null)
const ext = { width: 2560, height: 1440, refresh: 143.97, modes: ["2560x1440@59.95Hz", "2560x1440@143.97Hz", "2560x1440@144.00Hz", "2560x1440@120.00Hz", "1920x1080@60.00Hz", "3840x2160@30.00Hz"] }
assert.deepStrictEqual(X.resolutions(ext).map(r => r.value), ["3840x2160", "2560x1440", "1920x1080"])
assert.deepStrictEqual(X.rates(ext, 2560, 1440).map(r => r.id), ["2560x1440@143.97Hz", "2560x1440@120.00Hz", "2560x1440@59.95Hz"])
assert.strictEqual(X.currentMode(ext), "2560x1440@143.97Hz")
assert.strictEqual(X.currentMode({ width: 800, height: 600, refresh: 60, modes: [] }), "")
assert.strictEqual(X.modeFor(ext, "1920x1080"), "1920x1080@60.00Hz")
assert.strictEqual(X.modeFor(ext, "bogus"), "")
assert.deepStrictEqual([120, 59.94, 143.97, 60.001].map(X.rateDecimals), [0, 2, 0, 0])

// XDR.
assert.deepStrictEqual(X.xdrStops(600, 1600), [600, 800, 1000, 1300, 1600])
assert.deepStrictEqual(X.xdrStops(600, 1000), [600, 800, 1000])
assert.deepStrictEqual(X.xdrStops(600, 600), [])
assert.strictEqual(X.nitsNow(52, 600), 312)
assert.strictEqual(X.nitsNow(100, 1600), 1600)
assert.strictEqual(X.nitsNow(250, 600), 600)
s = X.parseState('{"xdr":{"supported":true,"max":1300,"sdr":600,"peak":1600,"nits":650,"range":1300}}')
assert.deepStrictEqual([s.xdr.max, s.xdr.range], [1300, 1300])

console.log("ok")
