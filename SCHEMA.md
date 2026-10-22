# JSON DSL v3 Reference

This document describes the executable `vars` / `steps` DSL accepted by `WorkflowParser` and the current device adapter. It is a format reference, not a JSON Schema validator. Unknown root and step fields are rejected. The single demo below is a complete, parseable workflow; the tables document its fields and execution rules.

## Full schema demo JSON

One parseable workflow showing every step type, all command fields, props defaults and overrides, nested expressions, and all OCR output forms. This is a syntax catalog, not a ready-to-run device script: calibrate coordinates, provide `child.json` as described under [Passing props](#passing-props-to-a-child-script), and replace or remove `template_match`, which the device adapter does not implement. Numeric OCR also requires regions containing valid numbers.

```json
{
  "version": 3,
  "label": "Full DSL v3 demo",
  "vars": {
    "props": {
      "rois": [
        [
          2041,
          589,
          111,
          46
        ]
      ],
      "expected_text": "吸收",
      "wait_ms": 1000
    },
    "count": 0,
    "text": "",
    "number": 0,
    "decimal": 0,
    "done": false,
    "match": null,
    "skill": null,
    "percentage": 0,
    "button_rois": [
      [
        2041,
        589,
        111,
        46
      ],
      [
        2041,
        715,
        111,
        46
      ]
    ],
    "wanted_text": "吸收",
    "index": 0
  },
  "steps": [
    {
      "type": "assign",
      "target": "${count}",
      "value": 0
    },
    {
      "type": "debug",
      "info": "${wanted_text}"
    },
    {
      "type": "while",
      "condition": "${count < 3}",
      "steps": [
        {
          "type": "assign",
          "target": "${count}",
          "value": "${count + 1}"
        },
        {
          "type": "if",
          "condition": "${count == 1}",
          "then": [
            {
              "type": "continue"
            }
          ],
          "else": []
        },
        {
          "type": "break"
        }
      ]
    },
    {
      "type": "while",
      "condition": "${index < props.rois.count}",
      "steps": [
        {
          "type": "ocr_text",
          "roi": "${props.rois[index]}",
          "output": "${text}"
        },
        {
          "type": "if",
          "condition": "${text contains props.expected_text}",
          "then": [
            {
              "type": "tap",
              "point": [
                "${props.rois[index][0] + props.rois[index][2] / 2}",
                "${props.rois[index][1] + props.rois[index][3] / 2}"
              ],
              "duration_ms": 100
            },
            {
              "type": "wait",
              "wait_ms": "${props.wait_ms}"
            },
            {
              "type": "break"
            }
          ]
        },
        {
          "type": "assign",
          "target": "${index}",
          "value": "${index + 1}"
        }
      ],
      "label": "Scan default ROIs and tap the first matching text"
    },
    {
      "type": "script",
      "script_name": "child.json",
      "props": {
        "rois": "${button_rois}",
        "expected_text": "${wanted_text}",
        "wait_ms": "${props.wait_ms}"
      },
      "label": "Call an external child with evaluated props"
    },
    {
      "type": "ocr_text",
      "roi": [
        100,
        200,
        300,
        80
      ],
      "output": "${text}"
    },
    {
      "type": "ocr_text",
      "roi": [
        100,
        300,
        80,
        40
      ],
      "output": "${number:int}"
    },
    {
      "type": "ocr_text",
      "roi": [
        100,
        350,
        80,
        40
      ],
      "output": "${decimal:double}"
    },
    {
      "type": "template_match",
      "roi": [
        100,
        200,
        300,
        80
      ],
      "template": "button.png",
      "threshold": 0.8,
      "output": "${match}"
    },
    {
      "type": "skill_check",
      "roi": [
        2276,
        1188,
        144,
        144
      ],
      "model": "default",
      "skill": "E",
      "threshold": 0,
      "output": "${skill}"
    },
    {
      "type": "circle_percentage",
      "roi": [
        1270,
        1270,
        72,
        72
      ],
      "profile": "default",
      "output": "${percentage}"
    },
    {
      "type": "tap",
      "point": [
        250,
        240
      ],
      "duration_ms": 100
    },
    {
      "type": "drag",
      "from": [
        501,
        1080
      ],
      "to": [
        501,
        880
      ],
      "duration_ms": 250
    },
    {
      "type": "wait",
      "wait_ms": "${props.wait_ms}"
    },
    {
      "type": "run_for",
      "duration_ms": 1000,
      "steps": [
        {
          "type": "while",
          "condition": true,
          "steps": [
            {
              "type": "wait",
              "wait_ms": 100
            }
          ]
        }
      ]
    },
    {
      "type": "run_until",
      "check_every_ms": 500,
      "timeout_ms": 30000,
      "check": [
        {
          "type": "ocr_text",
          "roi": [
            100,
            200,
            300,
            80
          ],
          "output": "${text}"
        },
        {
          "type": "assign",
          "target": "${done}",
          "value": "${text contains 'DONE'}"
        }
      ],
      "until": "${done}",
      "steps": [
        {
          "type": "while",
          "condition": true,
          "steps": [
            {
              "type": "wait",
              "wait_ms": 100
            }
          ]
        }
      ]
    },
    {
      "type": "return"
    }
  ]
}
```

## Document structure

| Field | Required | Type | Description |
| --- | --- | --- | --- |
| `version` | Yes | Integer | Must be `3`. |
| `label` | No | String | Human-readable annotation; does not affect execution. |
| `vars` | Yes | Object | Local variables and their literal JSON initial values. Declare every variable before referencing or assigning it. |
| `vars.props` | No | Object | Defaults for arguments accepted from a parent `script` call. Required when the caller supplies `props`, including `{}`. |
| `steps` | Yes | Array of steps | Executed in order. An empty array is valid. |

Variable names use ASCII letters, digits, and underscores, starting with a letter or underscore. `true`, `false`, `null`, and `contains` are reserved. Values may be null, booleans, finite numbers, strings, arrays, or objects. Initial values in `vars` are literal data: expressions there are not evaluated. Use an `assign` step for calculated initialization.

Every step requires `type` and accepts an optional string `label`. Fields shown below are required unless marked optional. Inputs accept JSON literals or an entire expression string such as `"${props.wait_ms}"`; arrays and objects in step inputs may contain expressions recursively. Destinations (`target` and `output`) have stricter rules.

## Passing props to a child script

The full demo below combines the parent argument example, the child OCR loop, and the command catalog into one workflow. The OCR loop uses `break` after a match so the remaining catalog steps can continue; `return` at the end stops the script.

The `script` step still references a separate `child.json`: child workflows cannot be embedded as a DSL field. That child must declare `rois`, `expected_text`, and `wait_ms` in its `vars.props`. To recreate the OCR helper from the demo, copy its `vars.props`, `vars.index`, and `vars.text` into a new v3 workflow and use only the labeled OCR `while` step as its `steps`. In that standalone child, `break` ends the final loop and the child completes. Do not copy the `script` call into the child, which would create a cyclic reference.

Props rules:

- Parent expressions are evaluated at the call using the parent's current variables. The entire `props` field can also be an object-valued expression, for example `"${props}"` for explicit forwarding.
- Passed keys must be declared in the child's `vars.props`. Unknown keys cause an error before child execution.
- Passed values replace defaults by key. This is a shallow merge: nested objects and arrays are replaced as complete values. Omitted keys keep their defaults; explicit null replaces a default with null.
- Values are not coerced to the default's type. Commands validate values when consumed, for example a wait requires a nonnegative integer.
- Each call gets fresh child variables. Child assignments do not update the parent. Props are not automatically forwarded to grandchildren. `script` has no return value or output binding.
- Omitting `props` preserves the child's defaults and works with DSL, recorded-event, and `run` sequence scripts. Supplying `props` is supported only for DSL children that declare `vars.props`.
- Use identifier-shaped property keys to access them with `${props.key}`. Object bracket lookup is not supported.

## Every step type: inputs and outputs

In the orchestration web page, select a `script` step to edit its optional `props` JSON field. Enter an object (values may contain expressions) or a quoted object expression such as `"${props}"`. Clear the field to omit `props`; `{}` explicitly supplies an empty argument object. Child defaults are edited under Variables as `props` inside `vars`.

| Type | Input fields | Output / behavior |
| --- | --- | --- |
| `assign` | `target`: `${declared_variable}`; `value`: any input | Replaces the local variable. Member/index destinations such as `${props.x}` are not allowed; assign a whole object instead. |
| `debug` | `info`: string | Writes the literal string or evaluated string parameter to the workflow log. |
| `while` | `condition`: boolean; `steps`: step array | Repeats while true. No automatic iteration limit or delay. |
| `if` | `condition`: boolean; `then`: step array; optional `else`: step array | Executes one branch; missing `else` does nothing. |
| `run_for` | `duration_ms`: positive integer; `steps`: step array | Runs the body once, cancels it at the deadline, waits for it to stop, then continues. If the body finishes early, continues immediately. |
| `run_until` | `check_every_ms`: positive integer; `timeout_ms`: positive integer; `check`: step array; `until`: boolean; `steps`: step array | Runs an initial check; if false, runs the body while checking periodically. A true condition cancels the body and continues; timeout throws. Body completion also ends this step. |
| `script` | `script_name`: nonempty string; optional `props`: object | Loads and runs a child synchronously. Relative paths resolve against the calling file. Arguments become child `vars.props`; no output value. |
| `ocr_text` | `roi`: rectangle; `output`: `${variable}`, `${variable:int}`, or `${variable:double}` | Stores recognized text, or a parsed number when a numeric suffix is used. |
| `template_match` | `roi`: rectangle; `template`: nonempty string; `threshold`: number from -1 to 1; `output`: `${variable}` | Parser support only. Current device adapter throws an unsupported-backend error; no device output contract is implemented. |
| `skill_check` | `roi`: rectangle; `model`: nonempty string; `skill`: nonempty string; `threshold`: number from 0 to 1; `output`: `${variable}` | Stores `{state, confidence, box, point}`. Current adapter requires `model: "default"` and `threshold: 0`. |
| `circle_percentage` | `roi`: rectangle; `profile`: nonempty string; `output`: `${variable}` | Stores a number from 0 to 1. Current adapter requires `profile: "default"` and a 72×72 ROI. |
| `tap` | `point`: `[x, y]`; `duration_ms`: positive integer | Touch down, hold, release. No variable output. |
| `drag` | `from`: `[x, y]`; `to`: `[x, y]`; `duration_ms`: positive integer | Touch down at `from`, move immediately to `to`, hold there, release. No interpolated trajectory. |
| `wait` | `wait_ms`: nonnegative integer | Waits with cancellation checks. Zero is valid. |
| `break` | None | Exits the nearest enclosing loop in the same execution scope. |
| `continue` | None | Starts the next iteration of the nearest enclosing loop in the same execution scope. |
| `return` | None | Stops the current DSL script. Its caller resumes after the `script` step. No return value. |

### Full step field documentation

These fields apply at every nesting level. Required means required for the listed step type. Input fields accept literals or whole expression strings; `type`, `label`, `target`, and `output` use the fixed forms described below. No other step fields are accepted.

| Step type(s) | Field | Required / default | Type and validation | Meaning |
| --- | --- | --- | --- | --- |
| All | `type` | Required | Literal string from the command table above | Selects the command. |
| All | `label` | Optional; omitted | Literal string | Annotation only. |
| `assign` | `target` | Required | `${declared_variable}` | Whole local variable to replace; no member/index or typed destinations. |
| `assign` | `value` | Required | Any JSON value or expression | Replacement value; nested arrays/objects may contain expressions. |
| `debug` | `info` | Required | String or string-valued expression | Writes `[Workflow] Debug: ...` to the workflow log. |
| `while`, `if` | `condition` | Required | Boolean | Loop condition or branch selector; no truthy coercion. |
| `while`, `run_for`, `run_until` | `steps` | Required | Array of steps, possibly empty | Body; timing and cancellation follow the command table. |
| `if` | `then` | Required | Array of steps, possibly empty | True branch. |
| `if` | `else` | Optional; empty branch | Array of steps | False branch. |
| `run_for`, `tap`, `drag` | `duration_ms` | Required | Positive integer, milliseconds | Body deadline or touch hold duration. |
| `run_until` | `check_every_ms` | Required | Positive integer, milliseconds | Periodic check interval after the initial check. |
| `run_until` | `timeout_ms` | Required | Positive integer, milliseconds | Timeout raises an error. |
| `run_until` | `check` | Required | Array of steps | Initial and periodic check; restricted commands and disjoint writes as documented below. |
| `run_until` | `until` | Required | Boolean | Evaluated after a check; true stops the body. |
| `script` | `script_name` | Required | Nonempty string | Child path; relative paths use the calling file's directory. |
| `script` | `props` | Optional; child's defaults | Object or object-valued expression | Shallow overrides of keys declared in child `vars.props`; no return binding. |
| All vision commands | `roi` | Required | `[x, y, width, height]` | Nonnegative finite origin, positive finite dimensions; must fit the frame. |
| `ocr_text` | `output` | Required | `${variable}`, `${variable:int}`, `${variable:double}` | Declared destination; plain text or validated numeric conversion. |
| Other vision commands | `output` | Required | `${variable}` | Declared destination; numeric suffixes are forbidden. |
| `template_match` | `template` | Required | Nonempty string | Template identifier; current device backend is unsupported. |
| `template_match` | `threshold` | Required | Number in [-1, 1] | Template match threshold; parser support only. |
| `skill_check` | `model` | Required | Nonempty string; adapter requires `default` | Classifier model. |
| `skill_check` | `skill` | Required | Nonempty string | Skill identifier, e.g. `E`. |
| `skill_check` | `threshold` | Required | Number in [0, 1]; adapter requires `0` | Classifier threshold. |
| `circle_percentage` | `profile` | Required | Nonempty string; adapter requires `default` | Ring detector profile; ROI must be 72×72 with integer coordinates. |
| `tap` | `point` | Required | `[x, y]` | Nonnegative finite on-screen coordinates. |
| `drag` | `from`, `to` | Both required | Each is `[x, y]` | Nonnegative finite on-screen start and end coordinates. |
| `wait` | `wait_ms` | Required | Nonnegative integer, milliseconds | Cancellable delay; zero is valid. |
| `break`, `continue`, `return` | No additional fields | — | Only `type` and optional `label` | Control flow; `break` and `continue` require an enclosing loop. |

### Vision outputs

| Operation | Output detail |
| --- | --- |
| Plain OCR | String; may be empty. Matching is a separate `if` condition. |
| OCR `:int` | Trims outer whitespace and parses the entire text. Requires a finite whole number with absolute value at most 9,007,199,254,740,991. Invalid text throws. |
| OCR `:double` | Trims outer whitespace and parses the entire text as a finite number. Invalid or empty text throws. |
| Skill state | `state` is `"usable"` or `"unusable"`; `confidence` is currently null; `box` is the ROI; `point` is its center. The configured classifier maps its `useable` / `not_useable` labels to these states. |
| Circle percentage | Fraction of colored ring samples in the 72×72 crop, using radii 30–36 px. White, translucent white, and gray are excluded. |

All output destinations must already exist in `vars`. Numeric output suffixes are supported only by OCR.

## Expressions and coordinates

| Syntax | Meaning |
| --- | --- |
| `${name}`, `${props.key}` | Variable or object member. Missing members throw. |
| `${rois[index]}`, `${rois[index][0]}` | Zero-based array indexing. Index must be an in-range integer. |
| `${rois.count}` | Array length. Object members named `count` remain ordinary members. |
| `+`, `-`, `*`, `/`, `%`; unary `+`, `-` | Numeric arithmetic; nonfinite results throw. `+` does not concatenate strings. |
| `==`, `!=` | JSON value equality/inequality. |
| `<`, `<=`, `>`, `>=` | Numeric comparisons. |
| `&&`, `\|\|`, `!` | Boolean logic; AND/OR short-circuit. |
| `${text contains 'expected'}` | Case-insensitive substring match after collapsing whitespace. Empty expected text never matches. |
| `(...)` | Grouping. |

Use boolean expressions for conditions; the string `"true"` is not a boolean. Strings inside expressions can use single or double quotes. Function calls, host code, string interpolation, object bracket lookup, and array/object construction inside expressions are unsupported. Use JSON arrays/objects with expression-valued elements instead.

ROI format is `[x, y, width, height]`; points are `[x, y]`. Coordinates are absolute pixels in the current device orientation, with a top-left origin. Coordinates must be nonnegative finite numbers and ROI dimensions positive. The device adapter rejects out-of-frame ROIs and out-of-screen touches. Decimal coordinates are permitted; the circle detector requires integer coordinates. Resolution changes require recalibration.

## Execution and validation

- Each workflow starts with fresh `vars`. Assignments and vision outputs are local to that invocation.
- `run_until.check` may use assignment, vision, conditions, and loops. It cannot contain `tap`, `drag`, `script`, `run_for`, `run_until`, `wait`, or `return`. Check and body cannot write the same variable. A break/continue in a check must target a loop inside that check.
- Timed bodies use cooperative cancellation. They stop and release held touches before execution proceeds. Explicit errors and parent cancellation propagate; timeouts in `run_until` are errors.
- `script` children load when that step executes. Paths may be relative or absolute. The device runner rejects cyclic DSL references and excessive nesting. `run` sequence files load their entries recursively.
- Workflow JSON is limited to 1 MiB. Step/input/expression nesting is bounded at 64 and expression text at 4096 characters. Script nesting is also bounded at 64.
- JSON does not allow comments; use `label`. Unknown DSL fields and undeclared variable references are errors.

## Other v3 file formats

The loader also accepts recorded-event files (`version`, `deviceWidth`, `deviceHeight`, `events`, optional `repeatCount` and `label`) and sequence files (`version`, `run`, optional `script_loop_count` and `label`). These are separate formats, not DSL step types.

| Format | Inputs | Behavior |
| --- | --- | --- |
| Recording | `events` with `type` (`touch`, `scroll`, `key`), `t` in seconds, and event-specific fields | Replays recorded events. Touch uses `action` 0/1/2 and normalized `relX`/`relY`; scroll also uses `hScroll`/`vScroll`; key uses `key`. `repeatCount` defaults to one and values below one are treated as one. |
| Sequence | Nonempty `run` array of filenames or objects with `name`, optional `id` and `label`; positive `script_loop_count` defaults to one | Executes entries in order per loop. IDs must be unique and nonempty; omitted IDs become `step_1`, etc. |

`props` belongs to a DSL `script` step and is not a `run` entry field. Old `battle` / `pickup` script types and legacy sequence conditions are unsupported.

## Verification

From `wuwa_adb`, compile and run the props tests and parse the single full demo in this document:

```sh
swiftc -module-cache-path /tmp/adbquick-module-cache -o /tmp/adbquick-props-check \
  Sources/WorkflowModel.swift Sources/WorkflowExpressionParser.swift \
  Sources/WorkflowParser.swift Sources/WorkflowRunner.swift \
  Sources/Script.swift Sources/FlowScript.swift Sources/TextStopCondition.swift \
  Tests/WorkflowPropsTests.swift
/tmp/adbquick-props-check
```
