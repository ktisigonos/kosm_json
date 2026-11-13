# kosm_json

JSON for kosm: two adapters enabling `edit`, and `generate` for `json`.

- `json` claims `.json` files: strict JSON, where a trailing comma is a syntax error (the file is
  refused with its line, as with any syntax error). It also writes whole files through
  `generate`, indented by two spaces.
- `jsonc` claims `.jsonc` files and also takes `//` and `/* */` comments and trailing commas. Pass
  `.lang = "jsonc"` for a `.json` file written that way, such as VS Code's `settings.json`.

Both can add an app's own include entry with `insert` (a key at the end of an object) and
`append` (an element at the end of an array): the entry goes on its own line after the last one,
indented like it, with comments left where they are and a trailing comma kept.

```zig
var settings = try output.edit(.{ .files = "~/.config/Code/User/settings.json", .lang = "jsonc" });
try settings.set("\"editor.fontSize\"", 16);                              // a key holding a dot is quoted
try settings.set(.{ "workbench.colorCustomizations", "editor.background" }, color);
```

Only the value's bytes change; comments, spacing and key order stay as they are.

| Value | Written as |
|---|---|
| string | a JSON string, escaped |
| color | a JSON string in the file's color format; default `#rrggbb` |
| integer, float | the number; floats at the file's precision, never infinity or NaN |
| bool | `true` or `false`; `format.boolean` must stay `.true_false` |
| struct, list | an object or array on one line |
| `kosm.raw(text)` | `text`, verbatim |

Paths name object keys only. Reach array elements with `nodes`, `elements` and `replace`; `nodes("")` is the top-level value, for a file that is one array.
