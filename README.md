# kosm_json

JSON for kosm: the `json` adapter, which claims `.json` and `.jsonc` files and enables `edit`.
Comments are allowed; trailing commas are not (the file is refused with its line, as with any
syntax error).

```zig
var settings = try output.edit(.{ .files = "~/.config/Code/User/settings.json" });
try settings.set("\"editor.fontSize\"", 16);                              // a key holding a dot is quoted
try settings.set(.{ "workbench.colorCustomizations", "editor.background" }, color);
```

Only the value's bytes change; comments, spacing and key order stay as they are.

| Value | Written as |
|---|---|
| string | a JSON string, escaped |
| color | a JSON string in the file's color format; default `#rrggbb` (D61) |
| integer, float | the number; floats at the file's precision, never infinity or NaN |
| bool | `true` or `false`; `format.boolean` must stay `.true_false` |
| struct, list | an object or array on one line |
| `kosm.raw(text)` | `text`, verbatim |

Paths name object keys only (D77). Reach array elements with `nodes`, `elements` and `replace`
(D80).
