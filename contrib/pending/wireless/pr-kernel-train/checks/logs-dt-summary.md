## Device tree check: ERROR (check could not run)

base `674542cf2e22` -> head `2fdad550cebb`; dtschema 2026.9

**Error:** head: dt-validate chunk 2 failed: KeyError: 'uint8-array'; head: dt-validate chunk 3 failed: KeyError: 'uint8-array'; head: dt-validate chunk 9 failed: KeyError: 'uint8-array'

| Class | Blocks | Base | Head | New | Fixed |
|---|---|---:|---:|---:|---:|
| schema | no | 27 | 27 | 0 | 0 |
| unmatched | no | 28 | 28 | 0 | 0 |
| dtc-warning | no | 725 | 726 | 1 | 0 |
| binding-warning | no | 3 | 3 | 0 | 0 |
| style | no | 53 | 63 | 11 | 1 |

### New advisory problems (4 groups)

<details><summary>show</summary>

- **dtc-warning** dtc unit_address_vs_reg: /soc@200000000/smc@28c600000/gpio@67500000: node has a unit name, but no reg or ranges property (`arch/arm64/boot/dts/apple/t6050-j716s.dts:192`) in `apple/t6050-j716s.dtb`
- **style** [line-length] line exceeds 80 columns (86) (`arch/arm64/boot/dts/apple/t6050-j716s.dts:221`) in `arch/arm64/boot/dts/apple/t6050-j716s.dts`
- **style** [line-length] line exceeds 80 columns (82) (`arch/arm64/boot/dts/apple/t6050-j716s.dts:520`) in `arch/arm64/boot/dts/apple/t6050-j716s.dts`
- **style** [property-order] property '#power-domain-cells' out of canonical order (should sort before 'power-domains') (`arch/arm64/boot/dts/apple/t6050-j716s.dts:234`) in `arch/arm64/boot/dts/apple/t6050-j716s.dts`

</details>

### Notes

- head: dt-validate chunk 2 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 3 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 9 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 10 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 4 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 5 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 6 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 11 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 7 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 17 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 13 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 14 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 12 failed: KeyError: 'uint8-array'
- head: dt-validate chunk 8 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 15 failed: KeyError: 'uint8-array'
- base: dt-validate chunk 16 failed: KeyError: 'uint8-array'

### Timings (s)

resolve 0.17, extract+config+dtbs 6.71, binding-closure 0.28, schema 31.07, dt-validate 4.19, dt_binding_check 0.76, dts-style 0.08, compare 0.0, total 43.35

