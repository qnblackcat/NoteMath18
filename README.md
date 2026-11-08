# NoteMath18

NoteMath18 brings the Math Notes calculations of iOS 18 to Apple Notes on iOS 15–17.

## Features

### Calculate as you type

- Type `=` after an expression and the result is suggested right after it (`1+1=2`, in yellow). Press space or return to accept it: the expression is tidied (`1+1` becomes `1 + 1`, `*` is shown as `x`) and the result plays a short colour animation. Type anything else, press backspace or move the caret, and the suggestion goes away.
- Results are recalculated live. Edit `3 x 3 = 9` into `3 x 4` and it becomes `= 12` once you pause typing.
- Undo and redo refresh the affected results too.
- Dates (`26-10-2026`), phone-like numbers (`0912-345-678`) and hex literals (`0x10`) are left alone.

### Variables

Define a variable with `name = value`, then use it in any calculation further down the note.

```text
a = 1
b = 2
c = -4
3a + 2b -5c = 27
```

- Several definitions fit on one line (`a = 1 b = 2`), and a definition can be an expression (`rent = 12 x 500`).
- A name can be redefined later in the note; the calculations below it use the newest value.
- Names are case-insensitive and may contain letters, digits and `_`.
- Change a definition and every calculation below that reads it is updated.
- A number written against a name or a bracket is multiplied with it: `2b`, `2pi`, `3(4+5)`.

### Colours, like iOS 18

- A result that is still correct turns yellow, the accent colour of Notes. When the expression changes and the result no longer matches, it goes back to plain text.
- The variables a correct calculation reads turn yellow with it, both in the calculation (`a` and `b` in `a + b = 3`) and in their definition lines.
- An expression that is well formed but has no value (`5 / 0`, `sqrt(-1)`, `ln(0)`, `tan(90)`, overflow) gets a red mark under the operand to blame.

### Tap a result

Tap a yellow result to select it and show the standard edit menu (Copy, Cut, Look Up, …). Requires iOS 16 or later.

## Supported expressions

- Addition, subtraction, multiplication (`*` or `x`), division, unary signs, parentheses and powers (`^`)
- Percentages, including relative ones such as `200 + 10% = 220`
- Constants `pi`, `π` and `e`
- `sqrt` (or `√`), `cbrt`, `abs`, `ln`, `log`, `exp`, `sin`, `cos`, `tan`, `asin`, `acos` and `atan`
- Angle suffixes `°`, `deg` and `rad`; trigonometric functions work in degrees by default
- Decimal and grouping separators follow your Region

## Limitations compared to iOS 18

- A wrong result you typed (`1+1=4`) stays as is, but it can be corrected when you edit that line later.
- The suggestion after `=` is real text until you accept or dismiss it; it stays in the note if Notes is closed first.
- Colours and animation are only drawn on this device locally, and are not synced between devices.
- No unit conversion (may come later?) and no graphs (will not come).

## Build

<details>
<summary>Build instructions</summary>

Build the package with roothide's fork of Theos. 

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide

```

</details>

## License

NoteMath18 is licensed under the GNU General Public License, version 3 only. See [LICENSE](LICENSE) for the complete license text.
