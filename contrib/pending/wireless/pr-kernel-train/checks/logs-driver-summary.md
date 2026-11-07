## Device tree check: PASS (no new blocking problems)

base `a873be047e9a` -> head `a0e28f1c1ab6`; dtschema 2026.9

| Class | Blocks | Base | Head | New | Fixed |
|---|---|---:|---:|---:|---:|
| binding-invalid | yes | 1 | 1 | 0 | 0 |
| binding-dropped | yes | 2 | 2 | 0 | 0 |
| example-build | yes | 1 | 1 | 0 | 0 |
| schema | no | 1011 | 1011 | 0 | 0 |
| dtc-warning | no | 690 | 690 | 0 | 0 |
| yamllint | no | 1 | 1 | 0 | 0 |
| style | no | 1 | 1 | 0 | 0 |

### Scope

- DT-related files changed: 2
- DTBs built: base 118, head 118; failing at head: 0
- DTBs depending on changed files: 0; output changed or new: 0
- schema check: full 0, limited to changed bindings 48
- bindings checked: 2
- fixed problems: 0

### Timings (s)

resolve 0.13, extract+config+dtbs 10.54, binding-closure 0.3, schema 31.33, dt-validate 6.26, dt_binding_check 0.69, compare 0.0, total 49.34

