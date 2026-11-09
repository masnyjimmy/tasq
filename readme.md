# tasq Language Specification

> **tasq** is a task runner language and interpreter designed as a modern, expressive replacement for limited task definition formats such as Justfile and Taskfile.
>
> **Status:** v0.1.0-beta. The language is feature-rich but may still change before v0.1.0.

---

## Table of Contents

1. [File Layout](#1-file-layout)
   - [1.1 Reserved Words](#11-reserved-words)
2. [Type System](#2-type-system)
   - [2.1 Runtime Types](#21-runtime-types)
   - [2.2 Special Types](#22-special-types)
   - [2.3 Meta Types](#23-meta-types)
   - [2.4 Argument Types](#24-argument-types)
3. [Bindings](#3-bindings)
4. [Expressions](#4-expressions)
   - [4.1 Operators](#41-operators)
   - [4.2 Strings and Interpolation](#42-strings-and-interpolation)
   - [4.3 If Expression](#43-if-expression)
   - [4.4 Switch Expression](#44-switch-expression)
   - [4.5 For Expression](#45-for-expression)
   - [4.6 Break and Continue](#46-break-and-continue)
   - [4.7 Fallback](#47-fallback)
   - [4.8 Lambdas](#48-lambdas)
   - [4.9 Ranges and Slices](#49-ranges-and-slices)
   - [4.10 Tuples and Destructuring](#410-tuples-and-destructuring)
   - [4.11 In Expression](#411-in-expression)
   - [4.12 With Expression](#412-with-expression)
5. [Built-in Functions](#5-built-in-functions)
6. [Process Calls](#6-process-calls)
   - [6.1 Statements and Expressions](#61-statements-and-expressions)
   - [6.2 Failure Handling](#62-failure-handling)
   - [6.3 Process Attributes](#63-process-attributes)
7. [Settings](#7-settings)
8. [Tasks](#8-tasks)
   - [8.1 Basic Syntax](#81-basic-syntax)
   - [8.2 Arguments](#82-arguments)
   - [8.3 Argument Ordering](#83-argument-ordering)
   - [8.4 Task Body](#84-task-body)
   - [8.5 If Statement](#85-if-statement)
   - [8.6 Switch Statement](#86-switch-statement)
   - [8.7 For Statement](#87-for-statement)
   - [8.8 Task Dependencies](#88-task-dependencies)
   - [8.9 In Statement](#89-in-statement)
9. [Task Calls](#9-task-calls)
10. [Groups](#10-groups)
    - [10.1 Named Groups](#101-named-groups)
    - [10.2 Anonymous Groups](#102-anonymous-groups)
11. [Command-Line Interface](#11-command-line-interface)
    - [11.1 Invocation](#111-invocation)
    - [11.2 Checking Without Running (`--check`)](#112-checking-without-running---check)
    - [11.3 Task Arguments](#113-task-arguments)
    - [11.4 Implicit CLI Names](#114-implicit-cli-names)
    - [11.5 Listing Tasks and Showing Usage](#115-listing-tasks-and-showing-usage)
    - [11.6 Choosing the File and Option Placement](#116-choosing-the-file-and-option-placement)
12. [Attributes](#12-attributes)
    - [12.1 Platform Attributes](#121-platform-attributes)
    - [12.2 Documentation Attributes](#122-documentation-attributes)
    - [12.3 Argument Attributes](#123-argument-attributes)
    - [12.4 Environment Attributes](#124-environment-attributes)
13. [Quick Reference](#13-quick-reference)
14. [Planned Features](#14-planned-features)

---

## 1. File Layout

A tasq file is a plain text file with no file extension. By default tasq looks for a file named **`tasq`**; another file can be selected with `-f` / `--file` ([§11.6](#116-choosing-the-file-and-option-placement)).

At the root (top) level it may contain the following elements, in any order:

| Element | Description |
|---------|-------------|
| Setting declarations | Global interpreter configuration ([§7](#7-settings)) |
| Binding declarations | Immutable named values ([§3](#3-bindings)) |
| Task definitions | Executable units of work ([§8](#8-tasks)) |
| Group definitions | Containers that share arguments across tasks ([§10](#10-groups)) |

### 1.1 Reserved Words

The following words are keywords. They cannot be used as the name of a binding, parameter, lambda parameter, capture, task or group:

```
task  group  set
if  else  switch  for  in  with
break  continue  fallback
and  or  not
true  false
```

The name `_` is also special: it is never defined and only discards a value ([§3](#3-bindings), [§8.4](#84-task-body)).

---

## 2. Type System

tasq uses three distinct type systems, each serving a different context. They are **not interchangeable**.

| Context | Type system |
|---------|-------------|
| Bindings and expressions (including values inside a task body, and lambda parameters) | Runtime types ([§2.1](#21-runtime-types), [§2.2](#22-special-types)) |
| Attribute values and setting values | Meta types ([§2.3](#23-meta-types)) |
| Task and group parameter declarations | Argument types ([§2.4](#24-argument-types)) |

### 2.1 Runtime Types

| Type | Description | Literal example |
|------|-------------|-----------------|
| `bool` | Boolean value | `true`, `false` |
| `char` | A single character | `'a'` |
| `number` | Integer or floating-point value | `42`, `3.14` |
| `string` | UTF-8 text | `"hello"`, `` `hello {name}` `` (see [§4.2](#42-strings-and-interpolation)) |
| `[]T` | Homogeneous ordered list of `T` | `[1, 2, 3]`, `[[1, 2], [3, 4]]` |
| `(T, U, ...)` | Fixed-size, heterogeneous tuple (see [§4.10](#410-tuples-and-destructuring)) | `("one", 1)`, `("a", 2, false)` |
| `lambda` | A single-expression function (see [§4.8](#48-lambdas)) | `\|a, b\| a > b` |

The types `void`, `noreturn` and `!T` also exist at runtime but have no literal form; see [§2.2](#22-special-types).

**Rules:**

- There is **no implicit type casting**. Use built-in functions for any conversion.
- Binding types are **inferred** from the assigned expression. Bindings never carry a type annotation.
- `[]T` may be **nested** (e.g. `[][]number`). All elements must share the same type.
- A list literal must **not be empty** where its element type cannot be determined from context.
- **Whole-number contexts.** Wherever a `number` is used in a place where a fractional value has no meaning (range bounds and slice bounds ([§4.9](#49-ranges-and-slices)), the position argument of `@at` ([§5](#5-built-in-functions)), and any similar place), it is first **rounded up to the next whole number** (ceiling): `1.2` becomes `2`, `2.0` stays `2`, `-1.5` becomes `-1`. This is not a type conversion and never raises an error; the value is still a `number`.
- A **tuple** has at least two elements, and each element has its own type. Its type is the ordered list of its element types, so `(string, number)` and `(number, string)` are different types. An element may be a `bool`, `char`, `number`, `string`, list, tuple or `lambda`; it cannot be `void`, `noreturn` or `!T`. Tuples may be nested and may be list elements (all elements of such a list must then have the identical tuple type). A tuple is created with a literal and taken apart by destructuring ([§4.10](#410-tuples-and-destructuring)).
- A `lambda` is a **template**: `|<params>| <expr>` has no fixed signature, and its parameter and result types are inferred from each use ([§4.8](#48-lambdas)). A lambda can be bound, aliased, passed to other lambdas, stored in a tuple and passed to built-ins that take a lambda ([§5](#5-built-in-functions)).
  - Every lambda literal has its own type, so two different lambdas cannot be mixed where a single type is required (for example as the elements of one list).
  - A lambda cannot return a lambda, or a tuple that contains a lambda, and cannot be a task or group argument ([§2.4](#24-argument-types)).
  - Lambdas can be compared and interpolated like other values ([§4.1](#41-operators), [§4.2](#42-strings-and-interpolation)), although this is rarely useful.

### 2.2 Special Types

These types have **no literal** and can only be produced by certain built-ins or keywords.

| Type | Meaning | Produced by |
|------|---------|-------------|
| `void` | "No meaningful value" | Built-ins such as `@print` |
| `noreturn` | The expression never yields a value; it always diverges | `@error(...)`, `break`, `continue` |
| `!T` | A fallible result: either a `T` or an error | `@env`, `@which`, `@parse_number`, `@at`, `@read` |

> **Notation.** The `!` in `!T` is type notation only. It is not an operator and cannot be written in source code. Boolean negation is written `not` ([§4.1](#41-operators)).

**`void`** is a real value that behaves as an ordinary concrete type. It can be assigned to a binding, and two `void` branches unify with each other, but a `void` branch does **not** unify with a differently typed branch (a `void` branch paired with a `string` branch is a type error).

**`noreturn`** can never be assigned to a binding.

**`!T`** can be used in exactly one way: by applying `fallback` ([§4.7](#47-fallback)) directly to the built-in call that produced it, yielding a plain `T`. It cannot be bound, passed to a process call or task call, stored in a list or tuple, used as a `with` subject ([§4.12](#412-with-expression)), or used in any other expression context.

**Unifying branches.** `if` ([§4.3](#43-if-expression)), `switch` ([§4.4](#44-switch-expression)), `for` ([§4.5](#45-for-expression)), `in` ([§4.11](#411-in-expression)) and `fallback` ([§4.7](#47-fallback)) combine several branches into one result type:

- All branches must produce the same type.
- A `noreturn` branch is the exception: it never yields a value, so it unifies with whatever type the other branches produce (e.g. `@error(...)`, or `break` / `continue` inside a `for` expression).
- If **every** branch is `noreturn`, the whole expression is `noreturn`.

### 2.3 Meta Types

Meta types are used **only** in attribute values and setting values. They are always **compile-time literals**: no expressions, variables, built-in calls or interpolation. In particular, a meta `string` must be a basic `"..."` literal; interpolated strings and process calls are not allowed.

| Type | Description | Literal example |
|------|-------------|-----------------|
| `null` | Absence of a value | `null` |
| `bool` | Boolean | `true`, `false` |
| `char` | A single character | `'a'` |
| `number` | Numeric value | `16` |
| `string` | Text | `"bash"` |
| `[]T` | Homogeneous list (may be empty: `[]`) | `["bash", "-c"]` |
| `(T,U,...)` | Fixed-size, heterogeneous sequence | `("some_string", 25)` |

- A meta `[]T` may be empty because the expected element type is always known from the consuming setting or attribute.
- A tuple's size is fixed by the number of types listed, and each position must match its declared type exactly. Element types may be any meta type, including lists and other tuples. The tuple *type* lists types, e.g. `(string,number)`; the tuple *literal* lists values, e.g. `("some_string", 25)`.
- Meta tuples are compile-time literals used only in attribute and setting values. They are unrelated to **runtime tuples** ([§4.10](#410-tuples-and-destructuring)), which are ordinary values built from expressions.
- A setting's type may be a **union** `T | U`, meaning either type is accepted. This is currently used only by the `dotenv` setting ([§7](#7-settings)).

### 2.4 Argument Types

Argument types are used in task and group parameter declarations. They are a restricted subset of runtime types, because command-line input must be representable as plain text tokens.

| Argument type | Runtime type | Positional? | Notes |
|---------------|--------------|:-----------:|-------|
| `string` | `string` | ✓ | |
| `number` | `number` | ✓ | Constrain to integers with `[int]` |
| `string_list` | `[]string` | | |
| `number_list` | `[]number` | | |
| `flag` | `bool` | | Implicit default `false` |

- Only positional types may be passed by position; every other type must be identified by name ([§8.3](#83-argument-ordering), [§11.3](#113-task-arguments)).
- `flag` is the only type with an **implicit default value**, and it takes no value on the command line.
- Tuples and lambdas are not argument types.

---

## 3. Bindings

A binding declares an **immutable, named value** with `:=`:

```
name := <expression>
```

A binding whose value is a tuple may instead **destructure** it into several names at once ([§4.10](#410-tuples-and-destructuring)):

```
a, b := <tuple expression>
label, (x, y) := <nested tuple expression>
```

**Rules:**

- A binding cannot be reassigned. Its type is inferred from the right-hand side.
- Bindings may be declared at file root, in a group body, or in a task body.
- Within one scope, binding names must be unique.
- Inside a task body, task arguments behave as immutable bindings of their runtime type.
- A binding named `_` is never defined; it only discards its value ([§8.4](#84-task-body)). Inside a destructuring pattern, `_` discards just that element.
- A binding is a declaration, not an expression. To name a value **inside** an expression (for example in the body of a lambda, which cannot contain declarations), use `with` ([§4.12](#412-with-expression)).

**Evaluation:**

| | Static bindings (file root, group body) | Task-local bindings (task body) |
|---|---|---|
| When | **Lazily**, on first reference | **Eagerly**, in statement order |
| How often | At most once per run; the result is cached | Every time the task runs |
| Environment | The environment of the scope they are **declared in**, never that of whichever task triggers them ([§12.4](#124-environment-attributes)) | The task's effective environment |
| Working directory | The root working directory (the `working_dir` setting, [§7](#7-settings)), never that of whichever task or `in` block triggers them | The working directory in effect at that point of the task, including any enclosing `in` ([§8.9](#89-in-statement)) |

Consequences:

- A static binding whose expression would diverge (e.g. calls `@error(...)`) only does so if something references it. An unused static binding is never evaluated.
- A static binding containing a process expression ([§6](#6-process-calls)) runs its command only on first reference, and only once. This makes it a convenient place to store a value such as a tool version that several tasks need.
- A **destructuring** static binding is one unit: referencing **any** of its names evaluates the whole right-hand side once, and every name of that binding then has its cached value.

**Examples:**

```tasq
// Root scope bindings
base_port := 8080
host      := "localhost"
debug     := false
tags      := ["release", "stable"]
matrix    := [[1, 2], [3, 4]]

// Evaluated lazily, once, on first use
zig_version := $`zig --version` fallback "unknown"

// Destructuring at root: evaluated lazily, once, when `major` or `minor` is first referenced
major, minor := (1, 14)

task example {
    // Task scope bindings
    prefix    := "build-"
    full_name := prefix + "output"
    $`echo {full_name}`
}
```

---

## 4. Expressions

Expressions produce a typed value. They are used in bindings, task call arguments, conditions and string interpolation.

### 4.1 Operators

| Category | Operators | Operands | Result |
|----------|-----------|----------|--------|
| Arithmetic | `+` `-` `*` `/` `%` | `number` | `number` |
| Comparison | `>` `<` `>=` `<=` | two `number`s or two `string`s ([see below](#string-comparison)) | `bool` |
| Equality | `==` `!=` | any matching type (tuples compare element-wise, [§4.10](#410-tuples-and-destructuring); lambdas compare by template, [§4.8](#48-lambdas)) | `bool` |
| Boolean | `and` `or` | `bool` | `bool` |
| Boolean negation | `not <expr>` | `bool` | `bool` |
| Unary minus | `-<expr>` | `number` | `number` |
| List spread | `[...list, item, ...]` | list `[]T`, items `T` | `[]T` |
| Range | `a..b`, `a..` | `number` | not a value; only valid as a `for` subject or a slice index ([§4.9](#49-ranges-and-slices)) |
| Slice | `value[a..b]` | `[]T` or `string`, and a range | same type as `value` ([§4.9](#49-ranges-and-slices)) |

**Rules:**

- There is **no implicit type coercion**; operands must match the expected types exactly.
- Precedence follows mathematical convention (`*`, `/`, `%` before `+`, `-`). Boolean operators bind more loosely than comparisons.
- **Boolean operator precedence.** From tightest to loosest: comparison and equality, then `not`, then `and`, then `or`. So `not a == b` means `not (a == b)`, `not a and b` means `(not a) and b`, and `a or b and c` means `a or (b and c)`. `not` may be repeated (`not not x`).
- There is **no `!` operator**. Boolean negation is always written `not`. The `!` of `!=` belongs to that operator only.
- The slice postfix `[...]` binds tighter than every operator. The range operator `..` binds more loosely than every arithmetic operator, so `a + 1..b * 2` means `(a + 1)..(b * 2)`.

```
if (not @exists("config.toml")) @error("missing config.toml")
ok := @all(nums, |n| n >= 0) and not @any(nums, |n| n > 100)
```

#### String comparison

`>` `<` `>=` `<=` also work on two `string` operands, which are compared **lexicographically** (for UTF-8 text this is the same as comparing code points). Both operands must have the same type; comparing a `number` with a `string` is a compile-time error, as there is no implicit coercion. `==` and `!=` compare strings for equality as for any other type.

```
"apple" < "banana"   // true
"abc" < "abd"        // true
"ab" < "abc"         // true  (a prefix is smaller than the longer string)
"b" >= "a"           // true
```

**List spread:**

```
base  := [1, 2, 3]
extra := [...base, 4, 5]  // [1, 2, 3, 4, 5]
```

**Modulo.** `a % b` is the remainder of truncated division:

- The result takes the **sign of the left operand**; the sign of the divisor does not matter.
- A zero result from a negative left operand is negative zero, printed as `-0`.
- A zero divisor does **not** raise an error; the result is `NaN` (currently printed as `-nan`).

```
a := [-3, 0, -5, 3, 3]
b := [3, 3, 3, -3, 0]

task test {
    for(a, b) |l, r| {
        @print(`{l} % {r} = {l % r}`)
    }
}
```

Output of `tasq test`:

```
-3 % 3 = -0
0 % 3 = 0
-5 % 3 = -2
3 % -3 = 0
3 % 0 = -nan
```

### 4.2 Strings and Interpolation

| Literal | Type | Interpolation | Description |
|---------|------|:-------------:|-------------|
| `"text"` | `string` | No | **Basic string.** Taken as written, apart from escape sequences. `{` and `}` have no special meaning. |
| `` `text {<expr>}` `` | `string` | Yes | **Interpolated string.** Any expression may be embedded using single curly braces. |
| `'c'` | `char` | No | A single character. |

Process calls are written `` $`command` `` ([§6](#6-process-calls)). There is no `$"..."` form.

**Interpolation.** Inside an interpolated string or a process call, `{<expression>}` is evaluated at runtime and converted to its string representation:

```
greeting := `Hello, {name}!`
url      := `http://{host}:{base_port + 1}`

$`echo "Running on {@os()} with {worker_count} workers"`
$`mkdir -p {output_dir}/{@env("BUILD_ID") fallback "local"}`
```

Lists and tuples are converted by converting each element and joining them with `, `; a list is wrapped in `[` `]` and a tuple in `(` `)`, e.g. `[1, 2, 3]` and `(str, 5, false)`. Strings inside them are written without quotes. A lambda (also one inside a tuple) is written as `<lambda>`.

Because `{` starts an interpolation in these literals, a literal brace must be escaped (`\{`, `\}`), for example in shell code:

```
$`awk '\{print $1\}' input.txt`
```

**Escape sequences** are valid in **every** literal kind (`"..."`, `` `...` ``, `` $`...` `` and `'c'`), even where an escape isn't strictly needed (e.g. `\{` inside a basic string):

| Escape | Meaning |
|--------|---------|
| `\n` `\t` `\r` | Newline, tab, carriage return |
| `\\` | Backslash |
| `\"` `\'` ``\` `` | Double quote, single quote, backtick |
| `\0` | Null character |
| `\xNN` | Character with the two-digit hexadecimal code `NN` |
| `\u{NNNN...}` | Unicode code point given as hexadecimal digits |
| `\{` `\}` | Literal `{` / `}` (prevents interpolation) |

Escapes are processed by tasq **before** a process call's command reaches the shell. To give the shell a literal backslash sequence such as `\n` (e.g. as an argument to `printf`), write the backslash twice: `` $`printf 'a\\nb'` ``.

### 4.3 If Expression

```
if (<condition>) <expression> else <expression>
```

- The condition must be a `bool`.
- The `else` branch is **required** in expression form. `else if` chains are supported.
- Branches are unified as described in [§2.2](#22-special-types).

```
mode    := if (@os() == "windows") "win" else "unix"
timeout := if (debug) 0 else 30
label   := if (score > 90) "A" else if (score > 80) "B" else "C"
target  := if (@exists("./config.toml")) "./config.toml" else @error("missing config.toml")
```

The statement form, with block bodies, is described in [§8.5](#85-if-statement).

### 4.4 Switch Expression

```
switch(<subject>) {
    <pattern> => <expr>,
    <pattern> => <expr>,
    else => <expr>,
}
```

- `<subject>` is evaluated once.
- **Every pattern in a `switch` must be unique**; a duplicate is a compile-time error.
- The `else` branch is **required** in expression form, since every subject value must produce a result.
- Branches are unified as described in [§2.2](#22-special-types). This is how `@error(...)` can serve as an `else` branch when there is no sensible fallback value.

```
rgb := switch(color) {
    "red"   => "#ff0000",
    "green" => "#00ff00",
    "blue"  => "#0000ff",
    else    => @error("Invalid color"),
}
```

The statement form is described in [§8.6](#86-switch-statement).

### 4.5 For Expression

A `for` expression maps, filters or otherwise processes one or more lists (or ranges) in lock-step and produces a **new list**. It is not wrapped in brackets:

```
for(<subjects>) |<captures>| <expr>
```

- `<subjects>` are one or more comma-separated subjects, each a list expression or a range ([§4.9](#49-ranges-and-slices)). They are iterated in lock-step over a shared window of indices: the **intersection** of the subjects' index intervals, where a list covers `0..@len(list)` and a range covers its own bounds. With only list subjects this is the length of the **shortest** subject; no error is raised. The full rules are in [§4.9](#49-ranges-and-slices).
- `<captures>` binds one capture to each subject, in order. A capture is an identifier (the current element of a list subject, or the current index of a range subject), `_` for a value you don't need, or a destructuring pattern `(a, b)` when the elements are tuples ([§4.10](#410-tuples-and-destructuring)). The number of captures **must equal** the number of subjects.
- `<expr>` is evaluated once per iteration, and its result becomes the corresponding element of the produced list. The result type is `[]T`, where `T` is the type of `<expr>`. If there are no iterations the result is an empty `[]T`.
- `<expr>` may be an `if`, `switch`, `in` or `with` expression containing `break` or `continue` branches ([§4.6](#46-break-and-continue)); these are `noreturn` and unify with the surviving branches ([§2.2](#22-special-types)).
- `<expr>` may itself be a `for` expression (a nested loop). The inner `for` produces a list, so the outer result is a list of lists.

```
input   := [1, 2, 3]
doubled := for(input) |i| i * 2

@print(`{doubled}`) // "[2, 4, 6]"

squares := for(0..5) |i| i * i  // [0, 1, 4, 9, 16]
```

The same loop shapes cover the common list operations, depending on what the body does:

| Body | Behaves as |
|------|------------|
| a plain value | map |
| a branch that is `continue` | filter |
| a branch that is `break` | take-while |
| a branch that is `@error(...)` | validate |

```
ports := [22, 0, 443, 70000, 8080, -5]
valid := for(ports) |p| if (p < 1 or p > 65535) continue else p   // [22, 443, 8080]
```

The statement form is described in [§8.7](#87-for-statement).

### 4.6 Break and Continue

`break` and `continue` are bare keywords (no arguments, no parentheses) that control iteration inside a `for`, in statement form ([§8.7](#87-for-statement)) or expression form ([§4.5](#45-for-expression)).

Both have type `noreturn` ([§2.2](#22-special-types)), so they can be used as branches of a nested `if`, `switch`, `in` or `with`.

| Keyword | In a `for` **statement** | In a `for` **expression** |
|---------|--------------------------|---------------------------|
| `break` | Stops iteration immediately. | Stops immediately and yields the list produced so far. |
| `continue` | Skips the rest of the current iteration and proceeds to the next. | Skips the current element (it is **not** added to the list) and proceeds. |

Both always refer to the **nearest enclosing `for`**; a nested `if`, `switch`, `in` or `with` does not change this, and neither does an inner `for`: in nested loops, `break` and `continue` affect only the innermost one. Leaving an `in` block this way restores the previous working directory ([§4.11](#411-in-expression)).

```
for(numbers) |n| {
    if (n < 0) continue
    if (n > 100) break
    @print(`{n}`)
}

positives := for(numbers) |n| if (n < 0) continue else n
```

### 4.7 Fallback

`fallback` supplies a replacement value when a call fails. It is an optional suffix attached **directly to the call**, valid after two kinds of call:

```
<builtin_call>       fallback <expression>
<process_expression> fallback <expression>
```

**After a built-in call.** Built-ins that can fail return `!T` ([§2.2](#22-special-types)), which is unusable until unwrapped, so `fallback` is **mandatory** for `@env`, `@which`, `@parse_number`, `@at` and `@read`. Using `fallback` after a built-in that cannot fail (e.g. `@len`) is a compile-time error.

**After a process expression.** A process expression aborts when its command exits non-zero ([§6.2](#62-failure-handling)), so `fallback` is **optional** there. On a non-zero exit, the fallback value replaces the process's output entirely. `fallback` cannot be combined with `nofail` (compile-time error).

`fallback` exists only on built-in calls and process expressions. A process **statement** has no `fallback` form.

**Rules:**

- **Short-circuiting:** if the call succeeds, its value is used and the fallback expression is never evaluated.
- The fallback expression must produce type `T` (for a process expression: `string`), or `noreturn` such as `@error(...)`, which unifies with `T` ([§2.2](#22-special-types)).
- The whole expression has type `T`, never `!T`, so it can be used anywhere a `T` can.
- The fallback expression extends **as far right as possible**: `@env("A") fallback "b" + "c"` means `@env("A") fallback ("b" + "c")`. Use parentheses to limit it: `(@env("A") fallback "b") + "c"`.
- Chains nest to the right: `@env("A") fallback @env("B") fallback "x"` tries `A`, then `B`, then `"x"`.

```
// Plain default value
path := @env("PATH") fallback ""

// Abort if PORT is not numeric
port := @parse_number(@env("PORT") fallback "8080") fallback @error("PORT must be numeric")

// Require a tool to be installed
zig := @which("zig") fallback @error("zig is not installed")

// Element access with a default
first := @at(names, 0) fallback "none"

// File content with a default
notes := @read("NOTES.md") fallback ""

// Process expression with a default
version := $`git describe --tags` fallback "dev"

// Process expression that aborts with a custom message
sha := $`git rev-parse HEAD` fallback @error(`not a git repository (status {@status_code()})`)
```

### 4.8 Lambdas

A **lambda** is a function written as a single expression:

```
|<params>| <expr>
```

```
double := |x| x * 2
add    := |a, b| a + b
```

Parameters are comma-separated names between the bars, with **no type annotations**. The body is one expression and extends as far right as possible.

**Binding.** Binding a lambda evaluates nothing; it creates a lambda value. Lambda bindings follow the ordinary binding rules ([§3](#3-bindings)): they may appear at file root, in a group body or in a task body, are immutable, and can be aliased (`twice := double`).

**Calling.** The meaning of `name(args)` depends on where it is written:

| Position | `name(...)` is |
|----------|----------------|
| Statement (a line of a task body) | a **task call** ([§9](#9-task-calls)) |
| Expression (right-hand side of `:=`, an argument, an interpolation, ...) | a **lambda call** |

- A lambda call takes positional arguments only, and their number must equal the number of parameters. Its value is the value of the body.
- To call a lambda whose body is `void` (e.g. it calls `@print`) for its effect, wrap the call in parentheses so it is an expression: `(say("hi"))`. Any other value must be used, or discarded with `_ :=` ([§8.4](#84-task-body)).

**Parameter types come from the use.** On each call, the argument types become the parameter types and the body is checked with them. For each distinct list of parameter types, tasq creates one *instance* of the lambda; all uses with those types share it. The same lambda can therefore be used with different types, as long as its body is valid for each:

```
show   := |v| `<{v}>`
double := |x| x * 2

task demo {
    @print(show(1))        // instance for (number): "<1>"
    @print(show("a"))      // instance for (string): "<a>"
    @print(`{double(21)}`) // 42
    _ := double("a")       // compile-time error: the body is not valid for (string)
}
```

**Checking.** A lambda body is checked in two stages:

1. **At the definition.** The body is analysed with parameters of *unknown* type. Everything that can be diagnosed without knowing the parameter types is reported right there (for example unknown names and other errors that do not depend on the parameter types); an operation whose validity depends on a parameter's type is deferred. A lambda that is never used is therefore still checked for these errors.
2. **At each instantiation.** The body is checked again with the concrete parameter types of that use. An error found here is reported with a trace: it points at the failing expression in the body, at the call that instantiated the lambda, and at the lambda's definition.

**Scope.** A lambda body is **lexically scoped**: it sees its own parameters and the names visible where the lambda is **written**, never the locals of its caller. (This concerns names only; the working directory is not a name, and a lambda is evaluated in the working directory in effect where it is called, see [§4.11](#411-in-expression).)

```
g := |k, h| h(k)

task test {
    k := 1
    f := |a| a + k          // this k is the task's k
    @print(`{g(5, f)}`)     // 6, not 10: g's own `k` (5) is not visible inside f
}
```

Parameters follow the no-shadowing rule of bindings: a parameter cannot share a name with an already visible name (compile-time error). Lambda parameters are plain names; they cannot be destructuring patterns.

**Lambdas as values.** A lambda can be bound, aliased, passed around and stored in a tuple:

```
apply := |fn, x| fn(x)

task demo {
    @print(`{apply(double, 4)}`)    // 8
}
```

It can also be passed to the built-ins that take a lambda ([§5](#5-built-in-functions)).

**Naming intermediate values.** A lambda body is one expression, so it cannot contain bindings. Use `with` ([§4.12](#412-with-expression)) to compute a value once and use it several times inside the body:

```
parse_repo := |line|
    with(@split(line, ";")) |parts| (
        @at(parts, 0) fallback @error("missing repo name"),
        @at(parts, 1) fallback @error("missing repo url"),
    )
```

**Equality and printing.** Lambdas can be compared with `==` and `!=`: two lambda values are equal when they refer to the exact same template. A lambda is converted to the string `<lambda>` in interpolation. The same holds for a tuple that contains a lambda, which is compared element-wise ([§4.10](#410-tuples-and-destructuring)). Neither is useful in practice, but both are allowed.

**Limits:**

- **No recursion.** A lambda cannot call itself, directly or through other lambdas (compile-time error).
- **A lambda cannot return a lambda**, nor a tuple that contains a lambda. `|a| |b| a + b` is a compile-time error (`lambda cannot return a lambda`). This is a deliberate part of the language, not a gap.
- A lambda body is an expression, so it cannot contain task calls or statements. Use a task for actions, and `with` to name intermediate values.
- A lambda cannot be a task or group argument ([§2.4](#24-argument-types)).

### 4.9 Ranges and Slices

A **range** is a pair of `number` bounds written with `..`:

```
range := <expr> '..' [<expr>]       // a..b    or    a..
```

- The **left** bound is required. The **right** bound may be omitted, which means "no upper end" (infinity).
- Bounds are `number` expressions, evaluated once, left to right. They are rounded up to whole numbers ([§2.1](#21-runtime-types)), and may be negative.
- A range is **half-open**: `a..b` covers the whole numbers `a, a+1, ..., b-1`. If `a >= b` the range is empty; this is never an error.
- A range is **not a value**. It cannot be bound, passed, stored, compared or interpolated; `r := 1..3` is a compile-time error. It is valid in exactly two places, and must be written directly there:

| Place | Written as | Meaning |
|-------|------------|---------|
| Subject of a `for` ([§4.5](#45-for-expression), [§8.7](#87-for-statement)) | `for(1..3) \|i\| ...` | **Range loop** |
| Index of an expression, as a postfix | `value[1..3]` | **Slice** |

#### Range loops

Every `for` subject contributes an interval of indices, and the loop runs over the **intersection** of all of them:

| Subject | Interval | Capture receives |
|---------|----------|------------------|
| List `[]T` | `0..@len(list)` | The element at the current index |
| Range `a..b` | `a..b` | The current index, as a `number` |
| Range `a..` | `a..` (no upper end) | The current index, as a `number` |

- The loop's **window** starts at the largest start and ends at the smallest end of all intervals, and iterates one index at a time. List elements are always read at their **absolute index**, which is what makes `for(list, 0..) |item, i|` bind `i` to the element's index.
- Because a list's interval starts at `0`, a range bound below `0` is **clamped to `0` whenever at least one subject is a list**. When **no** subject is a list, negative bounds are kept, which is useful for generating lists.
- If the window has **no finite end** (every subject is a range without a right bound), the loop runs **zero times**. A range loop can never be infinite; infinite loops do not exist in tasq.
- If the window's start is not below its end, the loop runs zero times. This is never an error.
- With only list subjects the window is `0..@len(shortest)`, which is the lock-step rule of earlier versions.

```
list := [0, 1, 2, 3, 4]

for(list, 1..3) |item, idx| {
    @print(`item: {item}, idx: {idx}`)
}
// item: 1, idx: 1
// item: 2, idx: 2

names := ["a", "b", "c"]

for(names, 0..) |name, i| @print(`{i}: {name}`)
// 0: a
// 1: b
// 2: c

for(names, 1..) |name, i| @print(`{i}: {name}`)
// 1: b
// 2: c

for(names, -5..2) |name, i| @print(`{i}: {name}`)
// 0: a
// 1: b   (start -5 is clamped to 0 because a list is present; the range ends at 2)

squares := for(0..5) |i| i * i   // [0, 1, 4, 9, 16]
around  := for(-2..3) |i| i      // [-2, -1, 0, 1, 2]  (no list, so negatives are kept)
nothing := for(0..) |i| i        // []                 (no finite end: zero iterations)
```

#### Slices

A slice `value[range]` copies part of a list or string. It follows the same index rules as a range loop, with the sliced value acting as the only list:

```
list := [0, 1, 2, 3, 4]
@print(`slice: {list[1..3]}`)   // slice: [1, 2]
```

- `value` is a list `[]T` or a `string`. The result has the same type as `value`: a list of `T`, or a string.
- The slice covers the indices `a..b` of `value`, clamped to `0..@len(value)`. An omitted right bound means the end of `value`.
- **A slice never errors.** Out-of-range bounds are clamped, and when nothing is left the result is an empty list or an empty string.
- For a string, an index is a character, the same unit that `@len` counts.
- A range is the **only** thing allowed inside the brackets. `list[1]` is a compile-time error; use `@at` ([§5](#5-built-in-functions)) to read a single element.
- The opening `[` of a slice must be on the **same line** as the end of `value`, otherwise it would be read as the start of an attribute list ([§12](#12-attributes)).
- Slices can be chained: `list[1..][0..2]` slices the result of the first slice.

```
list := [0, 1, 2, 3, 4]

list[3..]       // [3, 4]
list[-2..2]     // [0, 1]       negative start clamped to 0
list[2..100]    // [2, 3, 4]    end clamped to the length
list[4..2]      // []           start is not below end
list[10..]      // []

name := "tasq"
name[1..3]      // "as"
```

### 4.10 Tuples and Destructuring

A **tuple** groups a fixed number of values that may have different types.

```
pair   := ("str", 5)            // type (string, number)
triple := ("str", 5, false)     // type (string, number, bool)
nested := ("p", (1, 2))         // type (string, (number, number))
```

- A tuple literal is a comma-separated list of **two or more** expressions in parentheses. A parenthesized single expression is plain grouping, so there are no 0- or 1-element tuples.
- The element rules are in [§2.1](#21-runtime-types). Tuples are immutable, and there is **no field access** other than destructuring.
- `==` and `!=` compare two tuples of the same type element by element. Tuples of different types cannot be compared (compile-time error).
- In interpolation a tuple is shown in parentheses, e.g. `(str, 5, false)` ([§4.2](#42-strings-and-interpolation)).
- Tuples cannot be task or group arguments ([§2.4](#24-argument-types)).
- A tuple may contain a lambda. Such a tuple is compared and interpolated like any other ([§4.8](#48-lambdas)), but cannot be returned from a lambda.

#### Destructuring

Destructuring binds the elements of a tuple to separate names. A **pattern** is a name, `_`, or a parenthesized comma-separated list of two or more patterns:

```
pattern := name | '_' | '(' pattern ',' pattern { ',' pattern } ')'
```

It is allowed in three places:

| Place | Syntax | Notes |
|-------|--------|-------|
| Binding | `a, b := <tuple expr>` | The outermost pattern is written **without** parentheses. Nested patterns use parentheses: `label, (x, y) := <tuple expr>`. |
| `for` capture | `for(<subjects>) \|(a, b)\| ...` | A subject whose elements are tuples is captured with a parenthesized pattern. Plain captures may be mixed in: `\|(a, b), i\|`. |
| `with` capture | `with(<tuple expr>) \|(a, b)\| ...` | A subject that is a tuple is captured with a parenthesized pattern ([§4.12](#412-with-expression)). |

**Rules:**

- The pattern's shape must match the tuple's type **exactly**: the same number of elements at every level (compile-time error otherwise), and the right-hand side must be a tuple.
- `_` discards one element. It is never defined and may appear any number of times.
- The names a pattern introduces are ordinary bindings: they are immutable, must be unique within their scope and follow the no-shadowing rule of [§3](#3-bindings). A name bound by a `for` or `with` capture is visible only in that construct's body.
- Destructuring bindings are valid at file root, in a group body and in a task body. Evaluation is as in [§3](#3-bindings): task-local bindings run eagerly in statement order, and static bindings run **lazily and once**, when **any** of their names is first referenced.
- Destructuring is not available for lambda parameters or task and group arguments.

```
tuple_list := [
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4)
]

tuple := ("str", 5, false)

// Static destructuring: evaluated lazily, once, when `major` or `minor` is first used
major, minor := (1, 14)

task test {
    for(tuple_list) |(name, value)| {
        @print(`name: {name}, value: {value}`)
    }

    // Capture a tuple element together with the index
    for(tuple_list, 0..) |(name, _), i| {
        @print(`{i}: {name}`)
    }

    str, num, enabled := tuple

    // Nested pattern
    label, (x, y) := ("point", (3, 4))
}
```

### 4.11 In Expression

`in` changes the **working directory** for the duration of one expression or block, without a process call. Changing directory is a common operation, and `` $`cd` `` cannot do it properly: every process call is its own invocation ([§6](#6-process-calls)), so a `cd` inside one affects neither later process calls nor the built-in functions. `in` affects all of them.

```
in(<path>) <expression> else <expression>
```

`in` is a keyword ([§1.1](#11-reserved-words)). The statement form is described in [§8.9](#89-in-statement).

**Evaluation:**

- `<path>` is an expression of type `string`, evaluated once, first.
- A relative path is resolved against the working directory **in effect**, so nested `in` blocks compose. An absolute path is used as is.
- The path is **valid** when it exists and is a directory. If it is valid, the working directory becomes that directory and the first expression is evaluated. If it is not valid (it does not exist, or it is a file), the `else` expression is evaluated instead, in the working directory that was in effect around the `in`.
- The `else` branch is **required** in expression form, as for `if` ([§4.3](#43-if-expression)). The branches are unified as described in [§2.2](#22-special-types), so `@error(...)` is a typical `else` branch.

```
sources := in("src") @sort(@glob("*.zig"), |a, b| a < b) else @error("src/ is missing")
```

**What the working directory affects.** Inside `in`, the new working directory is used by:

- every process call ([§6](#6-process-calls));
- the built-ins `@glob`, `@exists`, `@read`, `@is_file`, `@is_dir` and `@cwd` ([§5](#5-built-in-functions)).

`@invocation_dir` is not affected. `in` also does not touch the **environment**: the body runs in the effective environment inherited from the enclosing context ([§12.4](#124-environment-attributes)), exactly as it would outside `in`, and the `.env` file ([§7](#7-settings)) is neither re-read nor re-located.

**Inheritance and restoration:**

- The previous working directory is **restored** when the `in` is left, however that happens: normally, through `break` or `continue` ([§4.6](#46-break-and-continue)), or by an abort (`@error(...)` or a failed process).
- A task called from inside an `in` block inherits the working directory, which reverts when the call returns; this is the same dynamic scoping as `[env]` ([§12.4](#124-environment-attributes)).
- A lambda is evaluated in the working directory in effect **where it is called**, not where it is written ([§4.8](#48-lambdas)).
- **Static bindings** ([§3](#3-bindings)) never see the working directory of whatever triggers them; they start from the root working directory (the `working_dir` setting, [§7](#7-settings)).

### 4.12 With Expression

`with` names one or more intermediate values **inside a single expression**. It is a building block for expression pipelines: compute a value once, then use it several times in the body. It matters most in lambda bodies ([§4.8](#48-lambdas)), which are a single expression and cannot contain bindings ([§3](#3-bindings)).

```
with(<subjects>) |<captures>| <expr>
```

- `<subjects>` are one or more comma-separated expressions. They are evaluated once each, **left to right**, before the body.
- `<captures>` binds one capture to each subject, in order. A capture is an identifier, `_` for a value you don't need, or a destructuring pattern `(a, b)` when the subject is a tuple ([§4.10](#410-tuples-and-destructuring)). The number of captures **must equal** the number of subjects (compile-time error otherwise).
- `<expr>` is the **body**. It extends as far right as possible, like a lambda body.
- The value and type of the whole `with` expression are those of the body. If the body is `noreturn`, so is the `with` expression ([§2.2](#22-special-types)).
- Unlike `for`, `with` does not iterate: the body is evaluated exactly once.

**Subjects.** A subject is an ordinary value, treated as the right-hand side of a binding would be. It may be of any type a binding can hold, but not `noreturn`, not a range ([§4.9](#49-ranges-and-slices)), and not a fallible result `!T`, which must first be unwrapped with `fallback` ([§4.7](#47-fallback), [§2.2](#22-special-types)). Subjects are evaluated each time the `with` expression is evaluated; nothing is cached.

**Scope.**

- Captured names are visible **only in the body**, never in the other subjects of the same `with`. To build a value from an earlier one, nest the expressions: `with(a) |x| with(f(x)) |y| ...`.
- Captured names follow the no-shadowing rule of bindings ([§3](#3-bindings)) and must be unique within one `with`. `_` may appear any number of times and is never defined.
- `with` does not change the working directory or the environment; unlike `in` ([§4.11](#411-in-expression)), the body runs exactly as it would outside the `with`.
- `break` and `continue` inside the body refer to the nearest enclosing `for`, as in a branch of `if` ([§4.6](#46-break-and-continue)).
- Inside a lambda, a `with` follows the two-stage checking of [§4.8](#48-lambdas): captured types are known only per instance.

**Expression only.** `with` has no statement form. In a task body, name a value with a binding (`name := ...`, [§8.4](#84-task-body)); a `with` written on its own line is an expression statement and is subject to the discarded-value rule of [§8.4](#84-task-body).

```
// Compute once, use twice: split the line a single time
parse_repo := |line|
    with(@split(line, ";")) |parts| (
        @at(parts, 0) fallback @error("missing repo name"),
        @at(parts, 1) fallback @error("missing repo url"),
    )

// A `with` body can be a `for` expression; `with` and `fallback` compose
read_repos := |file|
    with(@read(file) fallback @error(`{file} not found`)) |text|
        for(@lines(text)) |line|
            if (line == "") continue
            else parse_repo(line)

// Several subjects, each taken apart with a destructuring pattern
describe := |origin, p|
    with(origin, p) |(ox, oy), (px, py)| `dx={px - ox} dy={py - oy}`

// Nested `with`: the second subject uses the first capture
shout := |s|
    with(@trim(s, " ")) |t|
        with(@upper(t)) |u| `{u}!`

task print_repos {
    for(read_repos("repos.txt")) |(name, url)| {
        @print(`name: {name}, url: {url}`)
    }
}
```

---

## 5. Built-in Functions

Built-in functions are called with an `@` prefix and may appear in any expression.

**Environment and system**

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@env(key: string)` | `!string` | Value of environment variable `key` as visible in the current scope ([§12.4](#124-environment-attributes)), or an error if unset. There is no default-value overload; use `fallback`, e.g. `@env("PORT") fallback "8080"`. |
| `@which(name: string)` | `!string` | Path of program `name`, found like the unix `which` command: it is looked up in the `PATH` of the current scope's environment (so a `PATH` set with `[env]` is honored). Errors if not found. |
| `@os()` | `string` | The current platform: `"windows"`, `"linux"` or `"macos"`. |
| `@arch()` | `string` | The architecture **family** of the current platform. Its values are those of Zig's `builtin.target.cpu.arch.family()`, for example `"x86"` (both 32-bit and 64-bit x86), `"arm"`, `"aarch64"` or `"riscv"`. The exact set of values is that of the Zig version tasq is built with. |
| `@cwd()` | `string` | The absolute path of the working directory in effect: the `working_dir` setting ([§7](#7-settings)), or the directory entered by an enclosing `in` ([§4.11](#411-in-expression)). |
| `@invocation_dir()` | `string` | The directory from which tasq was called. Unlike `@cwd()` it is not affected by the `working_dir` setting or by `in`. |
| `@status_code()` | `number` | Exit status of the most recently executed process. Every process call, statement or expression, updates it, including a process expression evaluated as part of a lazily evaluated static binding ([§3](#3-bindings)). After a process that failed without aborting (`nofail`, or a taken `fallback`) it holds that non-zero status. Errors if no process has run yet in the current task. |

**File system**

Relative paths given to `@exists`, `@is_file`, `@is_dir`, `@read` and `@glob` are resolved against the working directory in effect ([§7](#7-settings), [§4.11](#411-in-expression)), the same one process calls run in. `@basename` and `@join_path` only work on strings and never touch the file system.

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@exists(path: string)` | `bool` | `true` if a file or directory exists at `path`. |
| `@is_file(path: string)` | `bool` | `true` if `path` exists and is a file. `false` if it is missing or is not a file. |
| `@is_dir(path: string)` | `bool` | `true` if `path` exists and is a directory. `false` if it is missing or is not a directory. |
| `@read(path: string)` | `!string` | The content of the file at `path`, exactly as stored (nothing is trimmed). Errors if the file cannot be read or is not valid UTF-8. |
| `@glob(pattern: string)` | `[]string` | Lists, recursively, the files and directories that match the glob `pattern`. The result is **not sorted** and its order is unspecified; use `@sort` for a deterministic order. An invalid pattern currently results in an empty list rather than an error ([§14](#14-planned-features)). |
| `@basename(path: string)` | `string` | The final component of `path`. Trailing separators are ignored. |
| `@join_path(parts: []string)` | `string` | Joins `parts` into one path using the **native path separator of the current operating system** (`\` on Windows, `/` elsewhere). |

**Output and control**

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@print(message: string)` | `void` | Prints `message`. Because it returns `void`, it can be used directly as a statement ([§8.4](#84-task-body)). |
| `@error(message: string)` | `noreturn` | Immediately aborts execution and reports `message`. Never produces a value ([§2.2](#22-special-types)). |

**Conversion**

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@parse_number(str: string)` | `!number` | Parses `str` as a `number`, or errors if it isn't a valid numeric literal. |

**Strings**

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@len(str: string)` | `number` | Number of characters in `str`. |
| `@at(str: string, pos: number)` | `!string` | The character at index `pos` of `str`, as a `string`. `pos` is rounded up to a whole number first ([§2.1](#21-runtime-types)); errors if the result is less than `0` or not less than `@len(str)`. |
| `@split(str: string, sep: string)` | `[]string` | Splits `str` wherever `sep` occurs. |
| `@join(strings: []string, sep: string)` | `string` | Joins the elements of `strings`, separated by `sep`. |
| `@lines(str: string)` | `[]string` | Cuts `str` into lines and returns them as a list. Lines end at `\n` or `\r\n`; the line terminators are not part of the returned lines. A final terminator does not produce an extra empty line, and an empty `str` yields an empty list. |
| `@lower(str: string)` | `string` | `str` in lowercase. |
| `@upper(str: string)` | `string` | `str` in uppercase. |
| `@contains(str: string, sub: string)` | `bool` | `true` if `str` contains `sub`. |
| `@starts_with(str: string, prefix: string)` | `bool` | `true` if `str` begins with `prefix`. |
| `@ends_with(str: string, suffix: string)` | `bool` | `true` if `str` ends with `suffix`. |
| `@replace(str: string, old: string, new: string)` | `string` | Copy of `str` with every occurrence of `old` replaced by `new`. |
| `@trim(str: string, set: string)` | `string` | Copy of `str` with all leading and trailing characters that occur in `set` removed. `set` is treated as a set of characters, not as a sequence. |
| `@trim_start(str: string, set: string)` | `string` | Like `@trim`, but removes only leading characters. |
| `@trim_end(str: string, set: string)` | `string` | Like `@trim`, but removes only trailing characters. |

**Lists**

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@len(list: []T)` | `number` | Number of elements in `list`. |
| `@at(list: []T, pos: number)` | `!T` | The element at index `pos` of `list`. `pos` is rounded up to a whole number first ([§2.1](#21-runtime-types)); errors if the result is less than `0` or not less than `@len(list)`. |
| `@replace(list: []T, old: T, new: T)` | `[]T` | Copy of `list` with every element equal to `old` replaced by `new`. |
| `@unique(list: []T)` | `[]T` | Copy of `list` without duplicates. Elements are compared with `==`; the first occurrence of each element is kept and the original order is preserved. |
| `@sort(list: []T, fn: \|T, T\| -> bool)` | `[]T` | Copy of `list` sorted using `fn`. `fn(a, b)` returns `true` when `a` must be ordered before `b` (a "less than" function). `list` itself is unchanged. |
| `@all(list: []T, fn: \|T\| -> bool)` | `bool` | `true` if `fn` is `true` for every element (vacuously `true` for an empty list). |
| `@any(list: []T, fn: \|T\| -> bool)` | `bool` | `true` if `fn` is `true` for at least one element. |
| `@reduce(list: []T, init: T, fn: \|T, T\| -> T)` | `T` | Folds `list` into a single value: starting from `init`, calls `fn(accumulator, element)` for each element in order and returns the final accumulator. |

**Notes:**

- **Overloads.** `@len`, `@at` and `@replace` each have a string and a list form. The overload is chosen at compile time from the argument types.
- **Lambda arguments.** `@sort`, `@all`, `@any` and `@reduce` take a lambda ([§4.8](#48-lambdas)), written inline or given by name (`@any(xs, big)` with `big := |n| n > 10`). The notation `|T| -> bool` means "a lambda taking one `T` and returning `bool`". The overload is chosen from the function name, the types of the non-lambda arguments and the lambda's **number of parameters**; the lambda's parameter types then come from that overload, and its body must produce the result type the overload expects (e.g. `bool` for `@any`).
- **Sort order.** The lambda given to `@sort` is a "less than" function: it should be a strict ordering (`fn(a, a)` is `false`, and `fn(a, b)` and `fn(b, a)` are never both `true`). The order of the result for a lambda that violates this is unspecified.
- **Fallible built-ins.** `@env`, `@which`, `@parse_number`, `@at` and `@read` return `!T` and can only be used with `fallback` ([§4.7](#47-fallback)).
- **Element access.** `@at` reads a single element or character. To take a part of a list or string, use a slice ([§4.9](#49-ranges-and-slices)), which never errors.

**Examples:**

```
task demo {
    // Every file and directory matching the pattern, in a deterministic order
    for(@sort(@glob("src/**/*.zig"), |a, b| a < b)) |path| @print(path)

    // Process output split into lines, each one trimmed
    for(@lines($`git status --short`)) |line| @print(@trim(line, " "))

    @print(@trim("--name--", "-"))                    // name
    @print(@trim_start("--name--", "-"))              // name--
    @print(@trim_end("--name--", "-"))                // --name

    @print(`{@unique([1, 2, 1, 3, 2])}`)              // [1, 2, 3]
    @print(`{@sort([3, 1, 2], |a, b| a < b)}`)        // [1, 2, 3]
    @print(`{@sort([3, 1, 2], |a, b| a > b)}`)        // [3, 2, 1]
    @print(`{@sort(["b", "c", "a"], |a, b| a < b)}`)  // [a, b, c]

    // Paths
    @print(@basename("src/main.zig"))                 // main.zig
    @print(@basename("src/lib/"))                     // lib
    @print(@join_path(["src", "lib", "main.zig"]))    // src/lib/main.zig (src\lib\main.zig on Windows)

    // File system
    if (@is_file("config.toml"))
        @print(@read("config.toml") fallback "")
}
```

> Additional built-in functions will be added in future versions.

---

## 6. Process Calls

A process call runs a shell command. It is written as a backtick literal prefixed with `$`, optionally with attributes between the `$` and the backtick:

```
$`<command>`
$[<attributes>]`<command>`
```

- Only `$` followed by a backtick literal is a process call; there is no `$"..."` form.
- `{<expr>}` interpolation and escape sequences work as in interpolated strings ([§4.2](#42-strings-and-interpolation)).
- Each `` $`...` `` literal is **one process invocation**. It runs using the interpreter from the `script` setting, in the working directory in effect (the `working_dir` setting ([§7](#7-settings)), or the directory entered by an enclosing `in` ([§8.9](#89-in-statement))), and in the environment described in [§12.4](#124-environment-attributes).
- Because every process call is its own invocation, a `cd` inside one does not carry over to later process calls or to built-in functions. To change the working directory, use `in` ([§4.11](#411-in-expression), [§8.9](#89-in-statement)).

### 6.1 Statements and Expressions

A process call is a **statement** when it stands alone as a line of a task body, and an **expression** when it appears where an expression is expected (a binding's right-hand side, an argument, inside an interpolation, a `with` subject, a static binding at file root or in a group body, and so on).

| Aspect | Process statement | Process expression |
|--------|-------------------|--------------------|
| Type | none | `string` |
| Echo | Command (after interpolation) is echoed first; `noecho` disables | None |
| stdout | Inherited | **Captured**; becomes the value |
| stderr | Inherited | Inherited |
| stdin | Inherited | Empty (reads end-of-file immediately; never waits for input) |
| Non-zero exit | Aborts execution | Aborts execution |
| `@status_code()` | Updated | Updated |
| `fallback` | None | Optional ([§4.7](#47-fallback)) |
| Valid attributes | `nofail`, `noecho` | `nofail` |

**Captured output.** For a process expression, every newline (`\n` or `\r\n`) at the **end** of the captured output is removed. Nothing else is trimmed: leading whitespace, trailing spaces and tabs, and newlines inside the output are preserved.

**Static bindings.** A process expression in a static binding runs lazily on first reference, once, and the result is cached ([§3](#3-bindings)). It runs in the environment and the working directory of the declaring scope ([§12.4](#124-environment-attributes), [§7](#7-settings)). Because every process updates `@status_code()`, that first reference can change the value `@status_code()` reports in the task that triggered it.

### 6.2 Failure Handling

A process fails when it exits with a non-zero status. By default this **aborts execution** with an error; there is no global switch to change that. Opt out per call:

| Form | On failure |
|------|------------|
| `` $`cmd` `` | Aborts execution (default) |
| `` $[nofail]`cmd` `` | Does not abort. A statement simply continues; an expression evaluates to whatever the command wrote to stdout (possibly nothing). The exit status is available via `@status_code()`. |
| `` $`cmd` fallback <expr> `` | Expression only: evaluates to `<expr>` instead |

`fallback` and `nofail` cannot be combined (compile-time error).

```
greeting := $`echo "Hello"`                       // "Hello"
branch   := $`git rev-parse --abbrev-ref HEAD`
version  := $`zig --version` fallback "unknown"

task probe {
    // Keep going on failure and inspect the outcome yourself
    out  := $[nofail]`zig --version 2>&1`
    tool := if (@status_code() == 0) out else "not installed"
    @print(tool)
}

task example {
    $`make build`                        // aborts if make fails
    $[nofail]`rm -f stale.lock`          // continues whatever happens
    @print(`rm exited with {@status_code()}`)
    $[noecho]`echo "this command is not echoed"`
}
```

### 6.3 Process Attributes

Process attributes are written inline, in a single bracket pair, comma-separated: `` $[nofail, noecho]`cmd` ``.

| Attribute | Valid on | Unique | Description |
|-----------|----------|:------:|-------------|
| `[nofail]` | statement, expression | Yes | A non-zero exit status does not abort execution ([§6.2](#62-failure-handling)). |
| `[noecho]` | statement | Yes | Do not echo the command before running it. The command's own output is unaffected. |

- Both are presence flags and take no value.
- Using an attribute where it is not valid (e.g. `noecho` on a process expression, where there is nothing to echo) is a compile-time error.
- Applying the same attribute twice to one process call is a compile-time error.

---

## 7. Settings

Settings configure global interpreter behavior. They are declared at **file root**, and **each setting may be declared only once** across the entire file.

**Single setting:**

```
set <name> = <meta_value>
```

**Boolean shorthand.** A `bool` setting with no value implicitly takes `true`:

```
set <boolean-setting>
```

**Block form.** Declares several settings in one statement. Block and single declarations may be mixed, as long as no setting name repeats:

```
set {
    <name> = <meta_value>
    <name> = <meta_value>
}
```

**Platform-conditional settings.** A platform attribute restricts a setting to one OS ([§12.1](#121-platform-attributes)):

```
[windows]
set script = ["cmd", "/C"]

[linux]
set script = ["bash", "-c"]

[macos]
set script = ["zsh", "-c"]
```

**Available settings:**

| Setting | Meta type | Description |
|---------|-----------|-------------|
| `script` | `[]string` | Command and arguments used to invoke each process call, e.g. `["sh", "-c"]`. |
| `dotenv` | `bool \| string` | Whether to read a `.env` file into the environment. `set dotenv` enables the default `.env` file in `working_dir`; `set dotenv = "path/to/file"` enables it using that file instead. Default: `false`. See [§12.4](#124-environment-attributes) for how loaded values interact with `[env]` and the OS environment. |
| `working_dir` | `string` | The root working directory: the working directory of tasq's spawned processes and of the file-system built-ins ([§5](#5-built-in-functions)); also used to resolve the default `.env` path. Defaults to the directory `tasq` was invoked from. Inside a task, `in` temporarily replaces it for a block ([§8.9](#89-in-statement)). |

> There is no setting to ignore process failures; see [§6.2](#62-failure-handling).
> Additional settings will be added in future versions.

---

## 8. Tasks

Tasks are the primary executable units in tasq: named, optionally parameterised blocks of instructions.

- Tasks **do not return values** and **cannot be used as expressions**.
- Tasks may be called from other tasks ([§9](#9-task-calls)) or run from the command line ([§11](#11-command-line-interface)).

### 8.1 Basic Syntax

```
task name {
    // task body
}

task name(
    param1: argument_type,
    param2: argument_type = default_value,
) {
    // task body
}
```

A task body is a *statement block* ([§8.4](#84-task-body)), so a body consisting of a single statement may omit its braces:

```
task name
    $`echo hello`
```

### 8.2 Arguments

Each argument is an optional attribute list, an identifier, a declared type and an optional default value:

```
task example(
    [<attributes>]
    identifier: argument_type,

    [<attributes>]
    identifier: argument_type = default_value,
) { ... }
```

- Argument types come from the argument type system ([§2.4](#24-argument-types)), not the runtime types.
- Default values are literals matching the argument's type.
- Inside the body, arguments are immutable bindings of their runtime type.
- Applicable attributes are listed in [§12.2](#122-documentation-attributes) and [§12.3](#123-argument-attributes); the CLI mapping is in [§11.3](#113-task-arguments).

### 8.3 Argument Ordering

An argument is **named** when it has a short name (`-x`), a long name (`--xyz`) or both: these are what a user types on the command line, as opposed to a positional argument, which is identified purely by position. CLI names are set with `[short]` / `[long]` ([§12.3](#123-argument-attributes)) or assigned implicitly ([§11.4](#114-implicit-cli-names)).

Arguments in a task or group declaration **must appear in this order**; violating it is a compile-time error.

| Phase | Kind | Characteristics |
|-------|------|-----------------|
| 1st | **Positional** | No name attribute; no default; only `string` and `number` |
| 2nd | **Named required** | Has a CLI name (explicit or implicit); no default |
| 3rd | **Named optional** | Has a CLI name (explicit or implicit); has a default (`= <value>`) |

**An argument becomes named automatically when:**

- it has a default value, making it named optional;
- its type is `flag`, `string_list` or `number_list`. These are inherently non-positional and are named required unless a default is given;
- it is a `group` argument. All group arguments are implicitly named required.

Positional arguments cannot have a default value (compile-time error).

```
task deploy(
    // 1. Positional
    target: string,

    // 2. Named required (flag type: implicitly named)
    verbose: flag,

    // 3. Named optional (default value: implicitly named)
    retries: number = 3,
) { ... }
```

### 8.4 Task Body

A task body may contain any combination of:

| Element | Syntax |
|---------|--------|
| Binding declaration | `name := <expr>`, or a destructuring binding `a, (b, _) := <tuple expr>` ([§4.10](#410-tuples-and-destructuring)) |
| Process statement | `` $`command` `` / `` $[attributes]`command` `` ([§6](#6-process-calls)) |
| If statement | `if / else if / else` ([§8.5](#85-if-statement)) |
| Switch statement | `switch(...) { ... }` ([§8.6](#86-switch-statement)) |
| For statement | `for(...) \|...\| { ... }` ([§8.7](#87-for-statement)) |
| In statement | `in(path) { ... } else { ... }` ([§8.9](#89-in-statement)) |
| Task call | `name(...)` / `::name(...)` / `group::name(...)` ([§9](#9-task-calls)) |
| Expression statement | Any other expression, e.g. `@print(msg)` |

**Expression statements.** A line that matches none of the other forms is parsed as an expression whose value is discarded. This is what lets `@print(...)` stand alone on a line: its type is `void`, so discarding it is harmless.

**Discarding values.** An expression statement whose value is not `void` (or `noreturn`) is a compile-time error (`discarded value`), because the value would be silently lost. To evaluate an expression and deliberately ignore its result, bind it to `_`:

```
_ := double(2)        // evaluated, result discarded
```

`_` is never defined as a name, so it cannot be read, and may be used any number of times in one scope.

**No statement form of `with`.** `with` ([§4.12](#412-with-expression)) exists only as an expression. In a task body, name a value with a binding (`name := ...`) instead.

**Statement blocks.** Wherever statements are expected (a task body, the branches of `if`, the body of `for`, the body of `in`, the body of a `switch` branch), the grammar accepts a *statement block*:

```
STMT_BLOCK := '{' STATEMENTS '}' | STATEMENT
```

A block with exactly one statement may omit its braces. This is one general rule, not a special form of any construct; a brace-less task such as `task build $`cc main.c`` is simply a consequence of it.

### 8.5 If Statement

`if` as a **statement** provides conditional control flow. Unlike the `if` expression ([§4.3](#43-if-expression)), branches contain statements rather than expressions, and `else` is optional.

```
if (<condition>) {
    // ...
} else if (<other_condition>) {
    // ...
} else {
    // ...
}
```

- The condition must be a `bool`.
- `else if` (any number) and `else` are optional.
- A branch with exactly one statement may omit its braces ([§8.4](#84-task-body)):

  ```
  if (something)
      @print(something)
  ```

### 8.6 Switch Statement

`switch` as a **statement** provides multi-way control flow. It produces no value and cannot appear inside an expression.

```
switch(<subject>) {
    <pattern> => <body>,
    <pattern> => <body>,
    else => <body>,
}
```

`<body>` is a single statement or a `{ }` block:

```
switch(color) {
    "red" => {
        $`echo "warm color"`
    },
    "blue" => $`echo "cool color"`,
    else => @error("Invalid color"),
}
```

- `<subject>` is evaluated once.
- **Every pattern must be unique** (compile-time error), as in the expression form ([§4.4](#44-switch-expression)).
- `else` is **optional**. If nothing matches and there is no `else`, execution continues after the `switch`.

### 8.7 For Statement

`for` as a **statement** iterates over one or more lists or ranges in lock-step, running a block for each step. Unlike the `for` expression ([§4.5](#45-for-expression)), it produces no value.

```
for(<subjects>) |<captures>| <stmt_block>
```

- `<subjects>` are one or more comma-separated subjects, each a list expression or a range ([§4.9](#49-ranges-and-slices)). They are iterated in lock-step over a shared window of indices: the **intersection** of the subjects' index intervals, where a list covers `0..@len(list)` and a range covers its own bounds. With only list subjects, iteration runs only for the length of the **shortest** subject; there is no out-of-bounds access and no error. The extra elements of longer subjects are never visited. A window with no finite end (only unbounded ranges) runs zero times. The full rules are in [§4.9](#49-ranges-and-slices).
- `<captures>` binds one capture to each subject, in order. A capture is an identifier (the current element of a list subject, or the current index of a range subject), `_` to ignore the value, or a destructuring pattern `(a, b)` when the elements are tuples ([§4.10](#410-tuples-and-destructuring)). The number of captures **must equal** the number of subjects.
- `<stmt_block>` is a `{ }` block or a single statement ([§8.4](#84-task-body)).
- `break` and `continue` ([§4.6](#46-break-and-continue)) may be used inside, including from a nested `if`, `switch` or `in`.

```
words   := ["one", "two", "three"]
numbers := [1, 2, 3]

for(words, numbers) |w, n| {
    @print(`{n} = {w}`)
}
```

Mismatched lengths:

```
xs := [1, 2, 3, 4, 5]
ys := ["a", "b", "c"]

for(xs, ys) |x, y| @print(`{x}{y}`)
// output: 1a, 2b, 3c  (3 iterations: bounded by the shortest subject, ys)
```

Ranges and iteration index:

```
list := [0, 1, 2, 3, 4]

for(list, 1..3) |item, idx| {
    @print(`item: {item}, idx: {idx}`)
}
// item: 1, idx: 1
// item: 2, idx: 2

for(list, 0..) |item, i| @print(`{i}: {item}`)   // index of every element
for(0..3) |i| @print(`{i}`)                      // 0, 1, 2
```

Tuple elements:

```
pairs := [("one", 1), ("two", 2)]

for(pairs) |(name, value)| @print(`{name} = {value}`)
```

### 8.8 Task Dependencies

A task can list other tasks that must run before its body. Dependencies are a bracketed list of **task calls** placed between the argument list (if any) and the body:

```
task name(arg: string) [dep_a(), dep_b("x")] {
    // body
}

task other [dep_a()] {
    // body
}
```

**Basics:**

- Each entry is an ordinary task call ([§9](#9-task-calls)): same scope resolution, argument passing and compile-time call errors.
- Dependencies run before the body, one after another, **in the order listed**. They never run in parallel.
- A dependency's arguments are ordinary expressions. They may use the task's **own arguments** (e.g. `[compile(target)]`), the group's shared arguments, static bindings and built-ins. The task body has not run yet, so its task-local bindings do not exist and cannot be used.
- The task's `[env]` attributes ([§12.4](#124-environment-attributes)) **apply to its dependencies**, as if the task had called them itself.
- Dependencies run in the working directory in which the task itself was called ([§9](#9-task-calls)).
- The list sits after the signature, so it is never confused with an attribute list ([§12](#12-attributes)), which precedes the `task` keyword.
- A task with dependencies may also have a brace-less body ([§8.4](#84-task-body)).
- Dependencies only **order** tasks. tasq never skips a task because its outputs are up to date.

#### Deduplication

A dependency that has already run is not run again. This is what makes a shared dependency (a `build` that both `test` and `lint` need) run once.

**Call trees.** Every *call* starts a new **call tree**: the task named on the command line ([§11](#11-command-line-interface)) and every task call statement in a body ([§9](#9-task-calls)) is the root of its own tree. A tree consists of the called task, its dependencies, their dependencies, and so on. Deduplication happens **inside one tree** and never across trees.

- **Identity.** A run is identified by the task together with its **resolved arguments**: defaults are filled in first, and for a task in a group the group's shared arguments are included. Arguments are compared by value, and lists element by element, in order. So `build()` and `build(release: false)` are the same run when `release` defaults to `false`, while `deploy("staging")` and `deploy("prod")` are different runs.
- **Skipping.** When a dependency's identity matches a run that already **finished** in the same tree, the dependency is skipped, silently.
- **The root is never skipped.** The task that starts a tree always runs.
- **Arguments are evaluated first.** A dependency's identity depends on its arguments, so they are evaluated even if the dependency then turns out to be skipped. Keep dependency arguments free of side effects.

**Evaluation order.** A dependency's arguments are evaluated right before that dependency starts, left to right through the list. A later dependency's arguments can therefore observe the effects of the earlier dependencies:

```
[generate(), show(@read("version.txt") fallback "none")]   // version.txt is read after generate() has run
```

**Failure.** The first failure aborts the whole run: the remaining dependencies and the body do not run, and tasq exits with a non-zero status.

**Cycles.** A task cannot depend on itself, directly or through other tasks. The compiler follows both dependency lists and task call statements in bodies, so each of the following is a compile-time error, and `tasq --check` reports the cycle:

```
task a [b()] { ... }
task b [a()] { ... }

task c { d() }
task d { c() }
```

A call that sits in a branch which never executes (for example inside `if (false)`) still counts.

**Examples:**

```
task build {
    @print("build")
}

task test [build()] {
    @print("test")
}

task release [build(), test()] {
    @print("release")
}
```

`build` is listed twice in the same tree (directly, and through `test`), so it runs once. Output of `tasq release`:

```
build
test
release
```

Different arguments are different runs:

```
task a(v: number) {
    @print(`A:{v}`)
}

task b [a(1)] {
    @print("B")
}

task c [a(2), b()] {
    @print("C")
}
```

Output of `tasq c`:

```
A:2
A:1
B
C
```

A diamond runs the shared task once:

```
task d { @print("D") }
task b [d()] { @print("B") }
task c [d()] { @print("C") }
task a [b(), c()] { @print("A") }
```

Output of `tasq a`: `D`, `B`, `C`, `A`, one per line.

A task call statement is not a dependency: it starts a new tree, so it runs even if the same task already ran. To share a run, list both tasks as dependencies of the same task ([§9](#9-task-calls)).

**Passing arguments and environment to a dependency:**

```
task compile(target: string) {
    $`cc main.c $CFLAGS -o {target}`
}

[env: ("CFLAGS", "-O2")]
task package(target: string) [compile(target)]
    $`tar czf {target}.tgz {target}`
```

`compile` receives `package`'s `target` and runs with `CFLAGS=-O2`.

**A Justfile-style project:**

```
host := $`uname -a`

[desc: "build main"]
task build
    $`cc *.c -o main`

[desc: "test everything"]
task test-all [build()]
    $`./test --all`

[desc: "run a specific test"]
task test(name: string) [build()]
    $`./test --test {name}`
```

### 8.9 In Statement

`in` as a **statement** changes the working directory for a block of statements. The semantics, which are shared with the expression form, are described in [§4.11](#411-in-expression): the path is resolved against the working directory in effect, the previous directory is restored however the block is left, and the environment is not changed.

```
in(<path>) <stmt_block>
[else <stmt_block>]
```

- `<path>` is an expression of type `string`, evaluated once.
- If the path exists and is a directory, the `<stmt_block>` runs with that directory as the working directory. Otherwise (the path does not exist, or is a file) the `else` block runs in the working directory that was in effect around the `in`.
- `else` is **optional**. If the path is not valid and there is no `else`, the block is skipped silently and execution continues after the `in`, as for a `switch` without a match ([§8.6](#86-switch-statement)).
- Both bodies are statement blocks, so single statements may omit their braces ([§8.4](#84-task-body)).
- `break` and `continue` ([§4.6](#46-break-and-continue)) may be used inside and refer to the nearest enclosing `for`; the working directory is restored first.
- `else` takes a statement block, and `in` is itself a statement, so chains such as `in("a") { ... } else in("b") { ... } else { ... }` need no extra syntax.
- Task calls inside the block inherit the working directory, which reverts when the call returns ([§9](#9-task-calls)).

```
task frontend {
    in("frontend") {
        $`npm ci`
        $`npm run build`
    } else {
        @error("the frontend/ directory is missing")
    }
}

// Built-in functions follow `in`; `$`cd`` could never do this
task tests {
    in("tests") {
        for(@sort(@glob("*.zig"), |a, b| a < b)) |file| $`zig test {file}`
    }
}

// Nested blocks compose, and the previous directory is restored
task nested {
    in("a") {
        in("b") {
            @print(@cwd())   // <start>/a/b
        }
        @print(@cwd())       // <start>/a
    }
}

// First existing directory wins
task output {
    in("dist") $`ls` else in("build") $`ls` else @error("nothing was built")
}
```

---

## 9. Task Calls

Tasks can be called from other task bodies. Task calls are **statements**: they produce no value and cannot appear inside expressions. (`name(...)` in expression position is a lambda call; see [§4.8](#48-lambdas).)

**Scope resolution:**

| Syntax | Resolves to |
|--------|-------------|
| `name(...)` | The nearest enclosing scope that defines `name` |
| `::name(...)` | The file root scope |
| `group_name::name(...)` | A specific named group |

**Argument passing.** Arguments may be passed **positionally** (in declared order) or **by name** (using the argument's identifier, in any order). Both styles may be mixed in one call as long as positional arguments come first:

```
// Positional
compile("main.rs", 4)

// By name
compile(
    target: "main.rs",
    jobs: 4,
)

// Mixed: positional first, then named
compile("main.rs", jobs: 4)
```

Names in task calls are the **argument identifiers** as declared in the signature, not the `[long]` / `[short]` CLI names.

When calling a task in a group from outside that group, the group's shared arguments must also be passed by identifier. A task called from inside its own group may omit them ([§10.1](#101-named-groups)).

**Inherited context.** A called task runs in the context of its caller: it inherits the effective environment ([§12.4](#124-environment-attributes)) and the working directory ([§4.11](#411-in-expression)) in effect at the call. Both revert when the call returns.

**Calls and dependencies.** A task call statement **always runs** the task, even if the same task with the same arguments already ran earlier in the invocation. It starts a new call tree ([§8.8](#88-task-dependencies)): the called task's own dependencies are deduplicated among themselves, but not against tasks that ran before the call. Calling `build()` twice in a body runs `build` twice. To run a shared task once, list it as a dependency instead.

```
task build { @print("build") }

task test [build()] { @print("test") }

task release [build()] {
    test()                // a new call: build() runs again inside it
    @print("release")
}
```

Output of `tasq release`: `build`, `build`, `test`, `release`. Writing `task release [build(), test()]` instead puts both in one call tree, and `build` runs once.

**Compile-time call errors:**

| Mistake | Example |
|---------|---------|
| Unknown task, group or argument name | `compil("main.rs")` |
| A positional argument after a named one | `compile(jobs: 4, "main.rs")` |
| More positional arguments than declared | `compile("main.rs", 4, true, "extra")` |
| The same argument supplied twice (by position and name, or twice by name) | `compile("main.rs", target: "other.rs")` |
| An argument of the wrong type | `compile(42)` for a `string` argument |
| A required argument not supplied (except a group's shared arguments in a call from inside the same group) | `compile()` |

An argument that declares a default value (including `flag`, whose implicit default is `false`) may be omitted.

---

## 10. Groups

Groups are containers for related tasks that share a common set of arguments.

### 10.1 Named Groups

```
group group_name(
    shared_arg: argument_type,
) {
    task task_a {
        // shared_arg is available here
    }

    task task_b(
        own_arg: string,
    ) {
        // both shared_arg and own_arg are available
    }
}
```

**Rules:**

- Groups **cannot be nested**.
- Group arguments are **promoted to named**: they implicitly receive CLI names following the same rules as non-positional argument types ([§11.4](#114-implicit-cli-names)).
- Group arguments are shared by every task in the group.
- Tasks in a named group are called from outside as `group_name::task_name(...)`.

**Calling tasks within a named group:**

```
// From outside the group: the shared arguments must be passed
some_group::some_task("positional_arg", shared_val: true)

// From inside the same group, by plain name: the shared arguments
// are already provided by the caller, so they may be omitted...
some_task("positional_arg")

// ...or passed explicitly, which overrides them for this call only
some_task("positional_arg", shared_val: false)
```

When a task calls another task of its own group, the callee receives the same shared-argument values as the caller. Passing one by name replaces that value for the duration of that call.

### 10.2 Anonymous Groups

An anonymous group works like a named group but has no identifier. Its shared arguments are treated as if declared in the root scope.

```
group(
    shared_arg: argument_type,
) {
    task task_a { ... }
    task task_b { ... }
}

// With no arguments
group {
    task task_a { ... }
    task task_b { ... }
}
```

- Anonymous groups cannot be targeted with `group_name::` scope resolution.
- The no-nesting rule applies: they cannot be placed inside another group.

---

## 11. Command-Line Interface

### 11.1 Invocation

```
tasq [COMMAND] [OPTIONS]...
tasq <task_name> [arguments...] [-f <file>]
```

**Commands:**

| Command | Description |
|---------|-------------|
| `tasq <task_name> [arguments...]` | Run a task. Arguments map to the task's declared arguments ([§11.3](#113-task-arguments)). |
| `tasq --check` | Run the diagnostics over the source file and print them, without running anything ([§11.2](#112-checking-without-running---check)). |
| `tasq --list` | Display the list of tasks ([§11.5](#115-listing-tasks-and-showing-usage)). |
| `tasq --usage <task_name>` | Display the usage of a task ([§11.5](#115-listing-tasks-and-showing-usage)). |
| `tasq --lsp` | Start the language server (LSP) on stdio, for editor integration. |
| `tasq --version` | Display the application version. |
| `tasq --help` | Print the help message of the command line interface itself (commands and global options). It does not list tasks; use `--list` for that. |

**Global options:**

| Option | Description |
|--------|-------------|
| `-f <file>`, `--file <file>` | Target file; overrides the default `tasq` ([§11.6](#116-choosing-the-file-and-option-placement)). |
| `-h`, `--help` | Show the help message. |

### 11.2 Checking Without Running (`--check`)

```
tasq --check
```

`--check` runs the compiler over the `tasq` file (parsing, name resolution, type checking and every other check the spec calls a *compile-time error*) and prints the resulting **diagnostics**. It then stops: **no task is run**.

**What it does not do:**

- It executes nothing. No task body runs, no process call is spawned (statement or expression), and no binding is evaluated.
- Because nothing runs, it cannot detect **runtime** failures: a command exiting non-zero, an `@error(...)` being reached, a missing environment variable, an unparsable `@parse_number` input, an `@at` position out of bounds, an unreadable `@read` file, and so on.
- Lambdas are checked in two stages ([§4.8](#48-lambdas)): at their definition, with parameters of unknown type, and at each use, with the concrete types. Errors that depend on a parameter's type can therefore only be found for lambdas that are used.

**Exit status.** `tasq --check` exits with a non-zero status when at least one error diagnostic is reported, so it can be used in scripts and CI.

### 11.3 Task Arguments

**Positional arguments** are passed by position, in declaration order. Only `string` and `number` may be positional.

```
tasq task_name value1 value2
```

**Named arguments** are identified by a long name (`--name`) or short name (`-n`). Any argument type can be named.

```
tasq task_name --output ./dist -j 4
```

**Flags** take **no value**: presence sets the argument to `true`, absence leaves the implicit default `false`.

```
tasq task_name --verbose
tasq task_name -v
```

**Mixing.** When a task has both kinds, positional arguments are consumed first in declaration order. Named arguments may appear anywhere in the command, except that the global `-f` / `--file` option must come last ([§11.6](#116-choosing-the-file-and-option-placement)).

### 11.4 Implicit CLI Names

Non-positional types (`string_list`, `number_list`, `flag`) automatically receive CLI names derived from their identifier:

| Implicit attribute | Default value |
|--------------------|---------------|
| `[short]` | First letter of the identifier |
| `[long]` | The full identifier |

Override or remove them with explicit `[long]` / `[short]` attributes ([§12.3](#123-argument-attributes)):

```
task example(
    [long: "tag", short: 't']  // custom names
    tags: string_list,

    [short: null]              // remove short; keep long (--verbose)
    verbose: flag,

    [long: null, short: 'x']   // remove long; custom short (-x)
    extra: flag,
) { ... }
```

### 11.5 Listing Tasks and Showing Usage

**`tasq --list`** displays the tasks of the file, grouped by group. Each task is shown with the names of its positional arguments and its `[desc]` description ([§12.2](#122-documentation-attributes)). `[private]` tasks and groups are omitted.

**`tasq --usage <task_name>`** displays the usage of one task: its signature, that is its arguments with their CLI names ([§11.3](#113-task-arguments), [§11.4](#114-implicit-cli-names)) and default values, together with the `[desc]` descriptions of the task and of its arguments.

```
tasq --list
tasq --usage build
```

### 11.6 Choosing the File and Option Placement

By default tasq reads the file named `tasq`. The global option `-f <file>` (or `--file <file>`) selects another file instead. It works with every command and with running a task, in which case it must be given **at the end** of the command line, after the task name and the task's arguments:

```
tasq test value1 -f "../tasq"    // runs task `test` with "value1", using the file ../tasq
tasq --list -f "../tasq"
```

**Help option.** `-h` / `--help` prints the help message when it is used as a command. Once a task name has been given, it neither prints the help message nor is it passed on to the task.

---

## 12. Attributes

Attributes annotate language elements to affect compilation, documentation, CLI naming, validation or process behavior. They are placed **directly before** the element they apply to:

```
[attribute_name]
[attribute_name: <meta_value>]
```

Several attributes may share one bracket pair, comma-separated, or be spread over several pairs (equivalent):

```
[int, min: 0, max: 100, desc: "A percentage value"]

[int]
[min: 0, max: 100]
[desc: "A percentage value"]
```

- Attribute values are **meta types**: compile-time literals ([§2.3](#23-meta-types)).
- **Process-call attributes** are the one exception to the placement rule: they are written inline between the `$` and the backtick ([§6.3](#63-process-attributes)).
- **Uniqueness** is a property of each attribute. A *unique* attribute may be applied at most once per element (twice is a compile-time error); a *repeatable* attribute may be applied multiple times. Each table below has a **Unique** column.

**Where each attribute is valid:**

| Attribute | `task` | `group` | argument | `set` | process stmt | process expr | Unique |
|-----------|:------:|:-------:|:--------:|:-----:|:------------:|:------------:|:------:|
| `[windows]` `[linux]` `[macos]` | ✓ | ✓ | | ✓ | | | Yes |
| `[desc]` | ✓ | ✓ | ✓ | | | | Yes |
| `[private]` | ✓ | ✓ | | | | | Yes |
| `[long]` `[short]` | | | ✓ | | | | Yes |
| `[int]` `[min]` `[max]` `[pattern]` `[max_items]` | | | ✓ | | | | Yes |
| `[env]` | ✓ | | | | | | No (repeatable) |
| `[nofail]` | | | | | ✓ | ✓ | Yes |
| `[noecho]` | | | | | ✓ | | Yes |

### 12.1 Platform Attributes

Restrict the element to one operating system. Elements with no platform attribute apply to **all** platforms.

| Attribute | Platform | Unique |
|-----------|----------|:------:|
| `[windows]` | Windows | Yes |
| `[linux]` | Linux | Yes |
| `[macos]` | macOS | Yes |

**Valid on:** `set` declarations, `group` definitions, `task` definitions.

```
[windows]
task open {
    $`start https://example.com`
}

[linux]
task open {
    $`xdg-open https://example.com`
}

[macos]
task open {
    $`open https://example.com`
}
```

### 12.2 Documentation Attributes

| Attribute | Meta type | Valid on | Unique | Description |
|-----------|-----------|----------|:------:|-------------|
| `[desc: "text"]` | `string` | `task`, `group`, argument | Yes | Human-readable description shown by `tasq --list` and `tasq --usage` ([§11.5](#115-listing-tasks-and-showing-usage)). |
| `[private]` | *(none)* | `task`, `group` | Yes | Hides the task or group from `tasq --list` output. A private task can still be called normally, by name from another task or directly from the command line; it is only omitted from generated documentation. |

```
[desc: "Compile and package the project for distribution"]
task build(
    [desc: "Number of parallel compilation jobs"]
    jobs: number = 4,

    [desc: "Target platform triple"]
    target: string,
) {
    $`cargo build --release --jobs {jobs} --target {target}`
}

// Internal helper: callable, but hidden from `tasq --list`
[private]
task _prepare_workspace {
    $`mkdir -p .cache/build`
}

task release {
    _prepare_workspace()
    $`cargo build --release`
}
```

### 12.3 Argument Attributes

Valid only on individual argument declarations inside tasks or groups.

**Naming.** `long` and `short` each come in three forms; each of the two attributes is unique.

| Attribute | Meta type | Description |
|-----------|-----------|-------------|
| `[long]` | *(none)* | Use the identifier as the long name (`--identifier`) |
| `[long: "name"]` | `string` | Use a custom long name |
| `[long: null]` | `null` | Remove the long name |
| `[short]` | *(none)* | Use the identifier's first letter as the short name (`-i`) |
| `[short: 'c']` | `char` | Use a custom short name |
| `[short: null]` | `null` | Remove the short name |

**Validation.** All are unique.

| Attribute | Meta type | Applies to | Description |
|-----------|-----------|------------|-------------|
| `[int]` | *(none)* | `number`, `number_list` | Integers only; reject floating-point input |
| `[min: n]` | `number` | `number`, `number_list` | Minimum allowed value (inclusive) |
| `[max: n]` | `number` | `number`, `number_list` | Maximum allowed value (inclusive) |
| `[pattern: "regex"]` | `string` | `string`, `string_list` | Validate each value against a regular expression |
| `[max_items: n]` | `number` | `string_list`, `number_list` | Maximum number of list items |

> Additional validation attributes will be added in future versions.

```
task create_user(
    // Positional
    username: string,

    // Named with validation
    [int, min: 13, max: 150, desc: "Age of the user"]
    age: number,

    // Custom CLI names and item limit
    [long: "tag", short: 't', max_items: 10]
    tags: string_list,

    // Optional with pattern validation
    [pattern: "^[\\w._%+\\-]+@[\\w.\\-]+\\.[a-z]{2,}$"]
    email: string = "",

    // Flag: long name kept, short removed
    [long, short: null]
    verbose: flag,
) {
    $`echo "Creating {username}, age {age}"`
}
```

### 12.4 Environment Attributes

| Attribute | Meta type | Valid on | Unique | Description |
|-----------|-----------|----------|:------:|-------------|
| `[env: (string,string)]` | `(string,string)` | `task` | No (repeatable) | Sets an environment variable for the task: the first tuple element is the name, the second the value. Write it once per variable to set several. |

**Scope:**

- An `[env]` variable is visible to `@env(...)`, `@which(...)` (which searches the `PATH` of that environment) and spawned processes (process calls) anywhere within the declaring task, including task-local bindings and process expressions. All three always see the same environment.
- If the task calls another task, including a dependency ([§8.8](#88-task-dependencies)), the variable is **inherited** by the callee and reverts when control returns to the caller. `[env]` is scoped dynamically to the call subtree rooted at the declaring task, not a permanent run-wide mutation.
- If a called task declares its own `[env]` for the same name, that value takes precedence for the duration of that call, and the earlier one resumes on return (ordinary nested shadowing).
- **Static bindings** ([§3](#3-bindings)) never see the `[env]` of the task that triggers them. They are evaluated in the environment of the scope they are declared in: the `.env` file (if enabled) and the OS environment.
- **Task-local bindings** see the task's effective environment: its own `[env]` plus whatever it inherited.
- `in` ([§4.11](#411-in-expression), [§8.9](#89-in-statement)) does not change the environment: its body inherits the effective environment of the enclosing context, like everything else.

**Precedence.** When a variable could come from several sources, the most specific wins:

1. `[env: (...)]` attributes in effect at the current point in the call chain
2. Values from a `.env` file, if the `dotenv` setting ([§7](#7-settings)) is enabled
3. The pre-existing OS environment

Static bindings start at step 2, since no `[env]` is in effect for them.

```
[env: ("NODE_ENV", "production")]
[env: ("LOG_LEVEL", "warn")]
task deploy {
    $`echo "Running in {@env("NODE_ENV") fallback "unknown"}"`
    build() // NODE_ENV and LOG_LEVEL are inherited here too
}
```

**Static vs. task-local bindings:**

```
// Static: always sees the root environment (shell braces are escaped)
layer := $`echo "$\{LAYER:-unset\}"`

[env: ("LAYER", "task")]
task show {
    @print(layer)                              // "unset" (if LAYER isn't set in the OS environment)
    local := $`echo "$\{LAYER:-unset\}"`
    @print(local)                              // "task"
}
```

---

## 13. Quick Reference

### Literals

| Literal | Type | Interpolation | Notes |
|---------|------|:-------------:|-------|
| `"text"` | `string` | No | Basic string |
| `` `text {expr}` `` | `string` | Yes (`{ }`) | Interpolated string |
| `'c'` | `char` | No | Single character |
| `("a", 1)` | tuple | No | Two or more elements of any value type, lambdas included ([§4.10](#410-tuples-and-destructuring)) |
| `\|a, b\| expr` | lambda | No | Single-expression function; types inferred per use ([§4.8](#48-lambdas)) |
| `` $`command {expr}` `` | process call | Yes (`{ }`) | Statement or expression ([§6.1](#61-statements-and-expressions)) |

Escape sequences (valid in every literal): `\n` `\t` `\r` `\\` `\"` `\'` ``\` `` `\0` `\xNN` `\u{NNNN...}` `\{` `\}`

### Boolean Operators

| Form | Meaning | See |
|------|---------|-----|
| `a and b`, `a or b` | Logical and / or | [§4.1](#41-operators) |
| `not a` | Logical negation (there is no `!` operator) | [§4.1](#41-operators) |
| precedence | comparison, then `not`, then `and`, then `or` | [§4.1](#41-operators) |

### Expression Forms

| Form | Meaning | See |
|------|---------|-----|
| `if (c) a else b` | Conditional expression | [§4.3](#43-if-expression) |
| `switch(x) { p => a, else => b }` | Multi-way expression | [§4.4](#44-switch-expression) |
| `for(list) \|x\| expr` | Builds a list: map, filter (`continue`), take-while (`break`), validate (`@error`) | [§4.5](#45-for-expression) |
| `with(expr) \|x\| expr` | Names a value inside an expression (expression only) | [§4.12](#412-with-expression) |
| `call() fallback x` | Replacement value when a call fails | [§4.7](#47-fallback) |
| `in(path) a else b` | Evaluate in another directory | [§4.11](#411-in-expression) |

### Ranges, Slices and Tuples

| Form | Meaning | See |
|------|---------|-----|
| `for(1..3) \|i\| ...` | Range loop over indices `1, 2` | [§4.9](#49-ranges-and-slices) |
| `for(list, 0..) \|item, i\| ...` | Loop with the element's index | [§4.9](#49-ranges-and-slices) |
| `list[1..3]`, `str[1..]` | Slice (never errors) | [§4.9](#49-ranges-and-slices) |
| `@at(list, 0) fallback x` | Single element or character (errors out of range) | [§5](#5-built-in-functions) |
| `a, b := tuple` | Destructuring binding | [§4.10](#410-tuples-and-destructuring) |
| `for(tuples) \|(a, b)\| ...` | Destructuring capture | [§4.10](#410-tuples-and-destructuring) |
| `with(tuple) \|(a, b)\| ...` | Destructuring capture in `with` | [§4.12](#412-with-expression) |

### Working Directory

| Form | Meaning | See |
|------|---------|-----|
| `in(path) { ... } else { ... }` | Statement: run a block in `path`; `else` optional | [§8.9](#89-in-statement) |
| `in(path) expr else expr` | Expression: evaluate in `path`; `else` required | [§4.11](#411-in-expression) |
| `@cwd()` | Working directory in effect | [§5](#5-built-in-functions) |
| `@invocation_dir()` | Directory tasq was called from | [§5](#5-built-in-functions) |

### Dependencies and Calls

| Form | Meaning | See |
|------|---------|-----|
| `task t [a(), b(1)] { ... }` | Run `a`, then `b(1)`, before the body; sequential, in order | [§8.8](#88-task-dependencies) |
| same task and same arguments, once per call tree | Runs once; later occurrences are skipped | [§8.8](#88-task-dependencies) |
| `a()` as a statement in a body | Always runs; starts a new call tree | [§9](#9-task-calls) |
| `a` depends on `b` and `b` on `a` | Compile-time error (also through call statements) | [§8.8](#88-task-dependencies) |

### Scope Resolution

| Syntax | Resolves to |
|--------|-------------|
| `name(...)` | Nearest enclosing scope |
| `::name(...)` | File root scope |
| `group_name::name(...)` | Specific named group |

### Which Type System Applies

| Context | Type system |
|---------|-------------|
| Binding values, expressions, values inside a task body, lambda parameters and results | Runtime types ([§2.1](#21-runtime-types), [§2.2](#22-special-types)) |
| Attribute values, setting values | Meta types ([§2.3](#23-meta-types)) |
| Task/group parameter declarations | Argument types ([§2.4](#24-argument-types)) |
| Result of a fallible built-in call | `!T`, unusable until unwrapped to `T` via `fallback` ([§4.7](#47-fallback)) |

### Where to Find Things

| Looking for | See |
|-------------|-----|
| Operators, precedence, `not` | [§4.1](#41-operators) |
| Reserved words | [§1.1](#11-reserved-words) |
| Ranges, range loops, slices | [§4.9](#49-ranges-and-slices) |
| Tuples, destructuring | [§4.10](#410-tuples-and-destructuring) |
| Changing the working directory (`in`) | [§4.11](#411-in-expression), [§8.9](#89-in-statement) |
| Naming values inside an expression (`with`) | [§4.12](#412-with-expression) |
| Process call defaults (echo, stdout, stdin, failure) | [§6.1](#61-statements-and-expressions) |
| Built-in function list | [§5](#5-built-in-functions) |
| Dependencies: order, deduplication, cycles | [§8.8](#88-task-dependencies) |
| Calling a task from a body | [§9](#9-task-calls) |
| Which attributes go where | [§12](#12-attributes) |
| CLI commands and options (`--check`, `--list`, `--usage`, `-f`, ...) | [§11](#11-command-line-interface) |

---

## 14. Planned Features

Reserved for future versions; not currently part of the language:

- **Precise string units.** `@len`, `@at` and string slices count "characters". The exact unit (Unicode code point, character or glyph) is to be decided and defined precisely ([§4.9](#49-ranges-and-slices), [§5](#5-built-in-functions)).
- **Additional built-in functions**: type conversion utilities and other helpers.
- **Glob errors.** An invalid pattern passed to `@glob` currently results in an empty list ([§5](#5-built-in-functions)). Reporting it as an error may be defined later.
- **Additional settings**: further interpreter configuration options.
- **Additional argument validation attributes.**
- **Isolated `@status_code()` for static bindings.** Today a lazily evaluated static binding that runs a process updates `@status_code()` like any other process; this may change so that evaluating a static binding leaves it untouched.
- **Eager evaluation of selected static bindings.** A way to force chosen static bindings to be evaluated at startup instead of on first reference.
- **Configurable stdin for process expressions.** They currently read an empty stdin.
- **Dependency identity.** Today a run is identified by the task and its resolved arguments only ([§8.8](#88-task-dependencies)). Two dependencies on the same task with the same arguments count as one run even if they sit under different `[env]` attributes or different `in` directories. A future version may make the effective `[env]` and the working directory part of the identity.