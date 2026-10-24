# tasq Language Specification

> **tasq** is a task runner language and interpreter designed as a modern, expressive replacement for limited task definition formats such as Justfile and Taskfile.

---

## Table of Contents

1. [File Layout](#1-file-layout)
2. [Type System](#2-type-system)
   - [2.1 Runtime Types](#21-runtime-types)
   - [2.2 Meta Types](#22-meta-types)
   - [2.3 Argument Types](#23-argument-types)
3. [Bindings](#3-bindings)
4. [Expressions](#4-expressions)
   - [4.1 Operators](#41-operators)
   - [4.2 String Literals and Interpolation](#42-string-literals-and-interpolation)
   - [4.3 If Expression](#43-if-expression)
   - [4.4 Switch Expression](#44-switch-expression)
   - [4.5 For Expression](#45-for-expression)
   - [4.6 Break and Continue Expressions](#46-break-and-continue-expressions)
   - [4.7 Built-in Functions](#47-built-in-functions)
   - [4.8 Fallback](#48-fallback)
   - [4.9 Process Expressions](#49-process-expressions)
   - [4.10 Lambdas](#410-lambdas)
5. [Settings](#5-settings)
6. [Tasks](#6-tasks)
   - [6.1 Arguments](#61-arguments)
   - [6.2 Argument Ordering](#62-argument-ordering)
   - [6.3 Task Body](#63-task-body)
   - [6.4 Process Calls](#64-process-calls)
   - [6.5 Conditional Statements](#65-conditional-statements)
   - [6.6 Switch Statement](#66-switch-statement)
   - [6.7 For Statement](#67-for-statement)
   - [6.8 Task Dependencies](#68-task-dependencies)
7. [Task Calls](#7-task-calls)
8. [Groups](#8-groups)
   - [8.1 Named Groups](#81-named-groups)
   - [8.2 Anonymous Groups](#82-anonymous-groups)
9. [Command-Line Interface](#9-command-line-interface)
10. [Attributes](#10-attributes)
    - [10.1 Platform Attributes](#101-platform-attributes)
    - [10.2 Documentation Attributes](#102-documentation-attributes)
    - [10.3 Modifier Attributes](#103-modifier-attributes)
    - [10.4 Environment Attributes](#104-environment-attributes)
    - [10.5 Process Attributes](#105-process-attributes)
11. [Quick Reference](#11-quick-reference)
12. [Planned Features](#12-planned-features)

---

## 1. File Layout

A tasq file is a plain text file named **`tasq`** with no file extension.

At the root (top) level, a tasq file may contain the following elements, in any order:

| Element | Description |
|---------|-------------|
| Setting declarations | Global interpreter configuration |
| Binding declarations | Immutable named values |
| Task definitions | Executable units of work |
| Group definitions | Containers that share arguments across tasks |

---

## 2. Type System

tasq uses three distinct type systems, each serving a different context. They are **not interchangeable**.

### 2.1 Runtime Types

Runtime types are used for bindings and expressions evaluated at runtime.

| Type | Description | Literal Example |
|------|-------------|-----------------|
| `bool` | Boolean value | `true`, `false` |
| `char` | A single character | `'a'` |
| `number` | Integer or floating-point value | `42`, `3.14` |
| `string` | UTF-8 text value | `"hello"`, `` `hello {name}` `` (see [§4.2](#42-string-literals-and-interpolation)) |
| `[]T` | Homogeneous ordered collection of type `T` | `[1, 2, 3]`, `[[1,2],[3,4]]` |
| `lambda` | A single-expression function, written `\|a, b\| a > b`; every lambda literal has its own type (see [§4.10](#410-lambdas)) | `\|a, b\| a > b` |
| `void` | The "no meaningful value" result of certain built-in functions | *(none — cannot be written as a literal)* |
| `noreturn` | Special type given to a built-in function call, or to `break`/`continue`, that never produces a value (it always diverges) | *(none — cannot be written as a literal)* |
| `!T` | Result of a fallible built-in function call: either a successful `T` value or an error | *(none — only produced by certain built-in functions)* |

**Rules:**

- There is **no implicit type casting**. Use built-in functions for any conversion.
- All binding types are **inferred** from the assigned expression. No explicit type annotation is written for bindings.
- `[]T` may be **nested** — `T` can itself be a list type (e.g. `[][]number`). All elements must share the same type.
- A `[]T` literal must **not be empty** at a point where its element type cannot be determined from context, since `T` cannot be inferred from an empty literal.
- A `lambda` is a **template**: `|<params>| <expr>` has no fixed signature, and its parameter types and result type are inferred from each use ([§4.10](#410-lambdas)). A lambda can be bound to a name, aliased, passed to other lambdas, and passed to built-in functions that take a lambda ([§4.7](#47-built-in-functions)). Every lambda literal has its own type, so two different lambdas cannot be mixed where a single type is required (for example as the elements of one list). A lambda cannot return a lambda, and a lambda is not a valid task or group argument type ([§2.3](#23-argument-types)).
- `void` has no literal and cannot be produced directly — it only ever appears as the return type of certain built-in functions (e.g. `@print`). Unlike `noreturn`, `void` **is** a real value and behaves as an ordinary concrete type: it can be assigned to a binding, and two `void`-typed branches unify with each other in `if`/`switch`/`for` — but a `void` branch does **not** unify with a differently-typed branch. Pairing a `void` branch with, say, a `string` branch is a type error.
- `noreturn` can never be assigned to a binding directly and has no literal form. It only ever appears as the return type of certain built-in functions ([§4.7](#47-built-in-functions)) or the `break`/`continue` expressions ([§4.6](#46-break-and-continue-expressions)). When a `noreturn`-typed branch appears alongside other branches — in an `if` expression ([§4.3](#43-if-expression)), `switch` expression ([§4.4](#44-switch-expression)), or `for` expression ([§4.5](#45-for-expression)) — it unifies with whatever type the other branches produce, since a diverging branch never actually yields a value to compare. If **every** branch is `noreturn`, the expression as a whole is `noreturn`.
- `!T` has no literal and is produced only by certain built-in functions ([§4.7](#47-built-in-functions)) that can fail. It cannot be assigned to a binding, passed to a process call or task call, stored in a list, or used in **any** other expression context — a `!T` value has exactly one valid use: applying `fallback` ([§4.8](#48-fallback)) directly to the built-in call that produced it. `fallback` unwraps a `!T` into a plain `T`, which can then be used anywhere a `T` is expected.

### 2.2 Meta Types

Meta types are used exclusively in **attribute values** and **setting values**. They are always **compile-time literals** — no expressions, variables, built-in calls, or interpolation of any kind are allowed. In particular, a meta `string` must be written as a basic `"..."` literal; interpolated strings ([§4.2](#42-string-literals-and-interpolation)) and process calls are not allowed.

| Type | Description | Literal Example |
|------|-------------|-----------------|
| `null` | Absence of a value | `null` |
| `bool` | Boolean | `true`, `false` |
| `char` | A single character | `'a'` |
| `number` | Numeric value | `16` |
| `string` | Text | `"bash"` |
| `[]T` | Homogeneous list | `["bash", "-c"]` |
| `(T,U,...)` | Fixed-size, heterogeneous sequence — each position has its own declared type | `("some_string", 25)` |

Meta type `[]T` may be **empty** (`[]`) because the expected element type is always known from the consuming setting or attribute definition.

A tuple's size is fixed by how many types are listed in `(T,U,...)`, and each position's value must match that position's declared type exactly — unlike `[]T`, a tuple's element types need not all be the same. A tuple's element types may themselves be any meta type, including a `[]T` or another tuple. Both the tuple *type* and the tuple *literal* are written with parentheses: the type lists types, e.g. `(string,number)`, while the literal lists values, e.g. `("some_string", 25)`.

A setting's meta type may also be a **union** of two meta types, written `T | U`, meaning a value of either type is accepted. This is currently only used by the `dotenv` setting (§5).

### 2.3 Argument Types

Argument types are used in task and group parameter declarations. They are a restricted subset of runtime types, because command-line input has to be representable as plain text tokens — a nested list or a lambda has no sensible textual form on the command line.

| Argument Type | Runtime Type | Positional? | Notes |
|---------------|--------------|:-----------:|-------|
| `string` | `string` | ✓ | |
| `number` | `number` | ✓ | Constrain to integers with `[int]` |
| `string_list` | `[]string` | | |
| `number_list` | `[]number` | | |
| `flag` | `bool` | | Implicit default: `false` |

**Notes:**

- Types marked positional may be passed either by position or by name on the command line. All other types must always be identified by name — see [§6.2](#62-argument-ordering) and [§9](#9-command-line-interface).
- `flag` is the only argument type with an **implicit default value**. It also receives special CLI treatment — no value is written after the flag's name (see [§9](#9-command-line-interface)).

---

## 3. Bindings

Bindings declare **immutable, statically-typed named values** using the `:=` operator.

```
name := <expression>
```

**Rules:**

- Once declared, a binding **cannot be reassigned**.
- The type is **inferred** from the right-hand side expression.
- Bindings may be declared in: file root scope, group body, or task body.
- Within the same scope, binding names must be unique.
- Inside a task body, arguments are treated as regular immutable bindings of their corresponding runtime type.
- A binding named `_` is never defined; it only discards its value ([§6.3](#63-task-body)).

**Evaluation order:**

- Bindings declared in a **static context** (file root scope or group body) are evaluated **lazily** — only when first referenced, not necessarily in the order they're written. The result is then **cached**: a static binding is evaluated at most once per run, however many times it is referenced.
- Bindings declared inside a **task body** are evaluated **eagerly, in statement order**, like any other statement in the task.

Two practical consequences:

- A static binding whose expression would diverge (e.g. it calls `@error(...)`, see [§4.7](#47-built-in-functions)) only does so if something actually ends up referencing it. An unused static binding's expression is never evaluated.
- A static binding that contains a process expression ([§4.9](#49-process-expressions)) runs its command only on first reference, and only once. This makes it a convenient place to store a value such as a tool version that several tasks need.

**Environment of static bindings:**

A static binding is evaluated in the environment of the scope it is **declared in**, never in the environment of whichever task happens to reference it first, so its value cannot depend on who triggers it. See [§10.4](#104-environment-attributes).

**Examples:**

```
// Root scope bindings
base_port := 8080
host      := "localhost"
debug     := false
tags      := ["release", "stable"]
matrix    := [[1, 2], [3, 4]]

// Evaluated lazily, once, on first use
zig_version := $`zig --version` fallback "unknown"

task example {
    // Task scope bindings
    prefix    := "build-"
    full_name := prefix + "output"
    $`echo {full_name}`
}
```

---

## 4. Expressions

Expressions produce a typed value. They are used in binding declarations, task call arguments, conditional conditions, and inside string interpolation.

### 4.1 Operators

| Category | Operators | Operand Type(s) | Result Type |
|----------|-----------|-----------------|-------------|
| Arithmetic | `+` `-` `*` `/` `%` | `number` | `number` |
| Comparison | `>` `<` `>=` `<=` | `number` | `bool` |
| Equality | `==` `!=` | any matching type | `bool` |
| Boolean | `and` `or` | `bool` | `bool` |
| Boolean negation | `!` | `bool` | `bool` |
| Unary minus | `-<expr>` | `number` | `number` |
| List spread | `[...list, item, ...]` | list: `[]T`, items: `T` | `[]T` |

**Rules:**

- There is **no implicit type coercion**. Operands must match the expected types exactly.
- Precedence follows standard mathematical convention (`*`, `/` and `%` before `+` and `-`). Boolean operators have lower precedence than comparisons.

**List spread example:**

```
base  := [1, 2, 3]
extra := [...base, 4, 5]  // [1, 2, 3, 4, 5]
```

**Modulo:**

`a % b` computes the remainder of dividing `a` by `b`, using truncated division:

- The result takes the **sign of the left operand** `a`. The sign of the divisor `b` does not affect the sign of the result.
- A zero result produced from a negative left operand is negative zero, and is printed as `-0`.
- A zero divisor does **not** raise an error; the result is `NaN` (currently printed as `-nan`).

```
a := [-3, 0, -5, 3, 3]
b := [3, 3, 3, -3, 0]

task test {
    for(a, b) |l, r, idx| {
        @print(`{idx + 1}. {l} % {r} = {l % r}`)
    }
}
```

Output of `tasq test`:

```
1. -3 % 3 = -0
2. 0 % 3 = 0
3. -5 % 3 = -2
4. 3 % -3 = 0
5. 3 % 0 = -nan
```

### 4.2 String Literals and Interpolation

tasq has three kinds of text literal:

| Literal | Type | Interpolation | Description |
|---------|------|:-------------:|-------------|
| `"text"` | `string` | No | **Basic string.** Its content is taken as written (apart from escape sequences). `{` and `}` have no special meaning. |
| `` `text {<expr>}` `` | `string` | Yes | **Interpolated string.** Any expression may be embedded using **single curly braces**. |
| `'c'` | `char` | No | A single character. |

Process calls are written with a `$` prefix on a backtick literal (`` $`command` ``) — see [§4.9](#49-process-expressions) and [§6.4](#64-process-calls). There is no `$"..."` form; only `` $`...` `` is valid.

**Interpolation:**

Inside an interpolated string, and inside a process call, any expression may be embedded using `{<expression>}`. The embedded expression is evaluated at runtime and converted to its string representation.

```
greeting := `Hello, {name}!`
url      := `http://{host}:{base_port + 1}`

$`echo "Running on {@os()} with {worker_count} workers"`
$`mkdir -p {output_dir}/{@env("BUILD_ID") fallback "local"}`
```

Because `{` begins an interpolation in these literals, a literal brace must be escaped (`\{`, `\}`), for example when writing shell code that uses braces:

```
$`awk '\{print $1\}' input.txt`
```

**Escape sequences:**

The following escape sequences are supported, and are valid in **every** literal kind (`"..."`, `` `...` ``, `` $`...` `` and `'c'`), even where an escape isn't strictly necessary (e.g. `\{` inside a basic `"..."` string):

| Escape | Meaning |
|--------|---------|
| `\n` | Newline |
| `\t` | Tab |
| `\r` | Carriage return |
| `\\` | Backslash |
| `\"` | Double quote |
| `\'` | Single quote |
| ``\` `` | Backtick |
| `\0` | Null character |
| `\xNN` | Character with the two-digit hexadecimal code `NN` |
| `\u{NNNN...}` | Unicode code point given as hexadecimal digits |
| `\{` | Literal `{` (prevents interpolation) |
| `\}` | Literal `}` |

Escapes are processed by tasq **before** a process call's command reaches the shell. To give the shell a literal backslash sequence such as `\n` (for example as an argument to `printf`), write the backslash twice: `` $`printf 'a\\nb'` ``.

### 4.3 If Expression

`if` can be used as an expression that evaluates to a value. This is the primary way to produce a conditional value inside a binding or any other expression context.

```
if (<condition>) <expression> else <expression>
```

**Rules:**

- The `else` branch is **required** when `if` is used as an expression.
- Both branches must produce the same runtime type; the result type is inferred from them — **unless** one of the branches has type `noreturn` (e.g. a call to `@error(...)`, or a `break`/`continue` inside a `for` expression), in which case the result type is inferred from the other branch alone (see [§2.1](#21-runtime-types)).
- `else if` chains are supported.

**Examples:**

```
mode    := if (@os() == "windows") "win" else "unix"
timeout := if (debug) 0 else 30
label   := if (score > 90) "A" else if (score > 80) "B" else "C"
target  := if (@exists("./config.toml")) "./config.toml" else @error("missing config.toml")
```

> The `if` **statement** form (with block bodies for control flow inside a task) is described in [§6.5 Conditional Statements](#65-conditional-statements).

### 4.4 Switch Expression

`switch` can be used as an expression that evaluates to a value, matching a subject against a series of patterns.

```
switch(<subject>) {
    <pattern> => <expr>,
    <pattern> => <expr>,
    else => <expr>,
}
```

**Rules:**

- `<subject>` is evaluated once. Rather than testing each `<pattern>` in turn at runtime, the set of patterns is hashed into a lookup table at compile time, and the subject's value is used as a key to jump directly to the matching branch. One consequence of this is that **every pattern in a given `switch` must be unique** — a duplicate pattern is a compile-time error.
- The `else` branch is **required** when `switch` is used as an expression, since every possible subject value must produce a result.
- Every branch's `<expr>` must produce the same runtime type — **except** branches with type `noreturn` (e.g. `@error(...)`, or `break`/`continue` inside a `for` expression), which unify with whatever type the other branches produce (see [§2.1](#21-runtime-types)). This is how a `switch` expression can use `@error(...)` in the `else` branch (or any branch) when there's no sensible fallback value.
- If every branch, including `else`, has type `noreturn`, the whole `switch` expression has type `noreturn`.

**Example:**

```
rgb := switch(color) {
    "red"   => "#ff0000",
    "green" => "#00ff00",
    "blue"  => "#0000ff",
    else    => @error("Invalid color"),
}
```

> The `switch` **statement** form (with block bodies for control flow inside a task) is described in [§6.6 Switch Statement](#66-switch-statement).

### 4.5 For Expression

`for` can be used as an expression that maps, filters, or otherwise processes one or more lists in lock-step, producing a new list. A `for` expression is used wherever an expression is expected (for example, on the right-hand side of a binding) and is **not** wrapped in brackets:

```
for(<subjects>) |<captures>| <expr>
```

**Rules:**

- `<subjects>` is one or more comma-separated list-valued expressions, iterated in lock-step. If the subjects don't all have the same length, iteration runs only for the length of the **shortest** one — no error is raised (see [§6.7](#67-for-statement) for an example).
- `<captures>` binds an identifier to the current element of each corresponding subject, in order. Use `_` for a capture whose value isn't needed. The number of captures must equal the number of subjects, **or** the number of subjects **+ 1** — the extra, final capture receives the current 0-based iteration index as a `number` (see [§6.7](#67-for-statement)).
- `<expr>` is evaluated once per iteration; its result becomes the corresponding element of the produced list. The overall result type is `[]T`, where `T` is the type of `<expr>`.
- `<expr>` may itself be an `if` or `switch` expression containing `break` or `continue` branches (both `noreturn` — see [§4.6](#46-break-and-continue-expressions)); such branches unify with whatever type the surviving branches produce, exactly as with `@error(...)`.

**Example:**

```
input := [1, 2, 3]

doubled := for(input) |i| i * 2

@print(`{doubled}`) // "[2, 4, 6]"
```

### 4.6 Break and Continue Expressions

`break` and `continue` are bare-keyword expressions (no arguments, no parentheses) used to control iteration from inside a `for` loop — statement form ([§6.7](#67-for-statement)) or expression form ([§4.5](#45-for-expression)).

**Type:**

Both have type `noreturn` (see [§2.1](#21-runtime-types)). Like `@error(...)`, they never produce a value themselves, so when used as a branch of a nested `if` or `switch`, they unify with whatever type the other branch(es) produce. This is what allows them to appear inside conditional logic nested within a `for` loop.

**Behavior:**

| Keyword | Inside a `for` **statement** | Inside a `for` **expression** |
|---------|-------------------------------|--------------------------------|
| `break` | Stops iteration immediately. | Stops iteration immediately and yields the list produced so far. |
| `continue` | Skips the remainder of the current iteration; proceeds to the next. | Skips the current element (it is **not** added to the produced list); proceeds to the next. |

`break` and `continue` always refer to the **nearest enclosing `for` loop** — an `if` or `switch` nested inside the loop body/expression does not change this.

**Examples:**

```
for(numbers) |n| {
    if (n < 0) continue
    if (n > 100) break
    @print(`{n}`)
}
```

```
positives := for(numbers) |n| if (n < 0) continue else n
```

### 4.7 Built-in Functions

Built-in functions are called with an `@` prefix and may appear inside any expression.

| Signature | Return Type | Description |
|-----------|-------------|-------------|
| `@env(key: string)` | `!string` | Returns the value of environment variable `key` as visible in the current scope (see [§10.4](#104-environment-attributes)), or an error if it is not set. There is no overload with a default value — use `fallback` ([§4.8](#48-fallback)) instead, e.g. `@env("PORT") fallback "8080"`. |
| `@which(name: string)` | `!string` | Looks up the program `name` in the `PATH` of the current scope's environment (see [§10.4](#104-environment-attributes)) — so a `PATH` set with `[env]` is honored — and returns its path, or an error if it is not found. Like `@env`, it needs `fallback` ([§4.8](#48-fallback)). |
| `@exists(path: string)` | `bool` | Returns `true` if a file or directory exists at `path`. |
| `@os()` | `string` | Returns the current platform: `"windows"`, `"linux"`, or `"macos"`. |
| `@status_code()` | `number` | Returns the exit status of the most recently executed process. Every process call — statement or expression — updates it, including a process expression evaluated as part of a lazily evaluated static binding ([§3](#3-bindings)). After a process that failed but did not abort (`nofail`, or a taken `fallback`), it holds that process's non-zero exit status. Errors if no process has been run yet in the current task. |
| `@error(message: string)` | `noreturn` | Immediately aborts execution and reports `message`. Never produces a value; see [§2.1](#21-runtime-types) for how a `noreturn` branch unifies with other branches in `if`/`switch`/`for` expressions. |
| `@print(message: string)` | `void` | Prints `message`. Because its return type is `void`, `@print(...)` can be used directly as a statement without binding its result (see [§6.3](#63-task-body)). |
| `@parse_number(str: string)` | `!number` | Parses `str` as a `number`, or returns an error if `str` isn't a valid numeric literal. |
| `@len(str: string)` | `number` | Returns the number of characters in `str`. |
| `@len(list: []T)` | `number` | Returns the number of elements in `list`. |
| `@split(str: string, sep: string)` | `[]string` | Splits `str` into substrings wherever `sep` occurs. |
| `@join(list: []string, sep: string)` | `string` | Joins the elements of `list` into a single string, separated by `sep`. |
| `@lower(str: string)` | `string` | Returns `str` converted to lowercase. |
| `@upper(str: string)` | `string` | Returns `str` converted to uppercase. |
| `@contains(str: string, sub: string)` | `bool` | Returns `true` if `str` contains `sub`. |
| `@starts_with(str: string, prefix: string)` | `bool` | Returns `true` if `str` begins with `prefix`. |
| `@ends_with(str: string, postfix: string)` | `bool` | Returns `true` if `str` ends with `postfix`. |
| `@replace(str: string, old: string, new: string)` | `string` | Returns a copy of `str` with every occurrence of `old` replaced by `new`. |
| `@replace(list: []T, old: T, new: T)` | `[]T` | Returns a copy of `list` with every element equal to `old` replaced by `new`. |
| `@all(list: []T, predicate: \|T\| -> bool)` | `bool` | Returns `true` if `predicate` evaluates to `true` for every element of `list` (vacuously `true` for an empty list). |
| `@any(array: []T, predicate: \|T\| -> bool)` | `bool` | Returns `true` if `predicate` evaluates to `true` for at least one element of `array`, otherwise `false`. `predicate` is a lambda, either a literal or a bound lambda (see [§4.10](#410-lambdas)); `\|T\| -> bool` denotes "a lambda taking one `T` and returning `bool`". |
| `@reduce(list: []T, init: T, combine: \|T, T\| -> T)` | `T` | Folds `list` into a single value: starting from `init`, repeatedly calls `combine(accumulator, element)` for each element in order, and returns the final accumulator. `\|T, T\| -> T` denotes "a lambda taking two `T`s (accumulator, then element) and returning a `T`". |

Several entries above share a name with different parameter types (`@len`, `@replace`) — the overload used is determined at compile time from the runtime type of the argument, the same way `[]T` itself is generic over `T`.

**Lambda arguments.** `@all`, `@any` and `@reduce` take a lambda, written inline or given by name (`@any(xs, big)` with `big := |n| n > 10`). The overload is chosen from the function name, the types of the non-lambda arguments and the lambda's **number of parameters**; the lambda's parameter types then come from the chosen overload, and the type of its body must match the result the overload expects (for example `bool` for `@any`).

Functions whose return type is `!T` (`@env`, `@parse_number`, `@which`) can fail; see [§4.8 Fallback](#48-fallback) for the only way to obtain a usable value from them.

> Additional built-in functions will be added in future versions.

### 4.8 Fallback

Some calls can fail. `fallback` supplies a replacement value for when they do. It is an optional suffix that is attached **directly to the call** and is valid after two kinds of call:

```
<builtin_call>       fallback <expression>
<process_expression> fallback <expression>
```

**After a built-in call:**

- Built-in functions that can fail return a **result type**, written `!T` ([§2.1](#21-runtime-types)) — either a successful `T` or an error. A `!T` cannot be stored, passed around, or used in any expression context. The only way to turn it into a usable `T` is `fallback`, so for these built-ins (`@env`, `@parse_number`, `@which`) it is **mandatory**.
- `fallback` after a built-in whose return type is not `!T` (for example `@len`) is a compile-time error: such a call cannot fail, so the fallback could never run.

**After a process expression:**

- A process expression is an ordinary `string` that aborts execution when its command fails ([§4.9](#49-process-expressions)), so `fallback` is **optional** here. When the command exits with a non-zero status, the fallback value replaces the process's output entirely.
- `fallback` cannot be combined with the `nofail` attribute ([§10.5](#105-process-attributes)): a `nofail` process never fails, so the fallback could never run. This is a compile-time error.

`fallback` exists only on built-in calls and process expressions. A process **statement** (a process call standing on its own) has no `fallback` form.

**Rules (both cases):**

- Evaluation is **short-circuiting**: if the call succeeds, its value is used and the `fallback` expression is never evaluated. The `fallback` expression only runs if the call actually failed.
- The `fallback` expression must produce type `T` (for a process expression: `string`) — **or** `noreturn` (e.g. `@error(...)`), in which case it unifies with `T` exactly as `noreturn` branches do elsewhere (see [§2.1](#21-runtime-types)).
- The overall expression has type `T` (never `!T`), so it can be used anywhere an ordinary `T` value can: assigned to a binding, interpolated, passed as an argument, and so on.
- The `fallback` expression extends **as far to the right as possible**. `@env("A") fallback "b" + "c"` means `@env("A") fallback ("b" + "c")`. Use parentheses to limit it: `(@env("A") fallback "b") + "c"`.
- `fallback` chains nest to the right: `@env("A") fallback @env("B") fallback "x"` tries `A`, then `B`, then `"x"`.

**Examples:**

```
// Falls back to a plain default value
path := @env("PATH") fallback ""

// Falls back to aborting the program (noreturn unifies with number)
port := @parse_number(@env("PORT") fallback "8080") fallback @error("PORT must be numeric")

// Require a tool to be installed
zig := @which("zig") fallback @error("zig is not installed")

// Process expression with a default
version := $`git describe --tags` fallback "dev"

// Process expression that aborts with a custom message; @status_code() holds the failed exit status
sha := $`git rev-parse HEAD` fallback @error(`not a git repository (status {@status_code()})`)
```

### 4.9 Process Expressions

A process call written as `` $`command` `` can be used as an **expression**. The command is run, and the expression evaluates to what the process wrote to stdout, as a `string`.

```
$`<command>`
$[<attributes>]`<command>`
$`<command>` fallback <expression>
```

**Rules:**

- Only `$` followed by a backtick literal is a process call. There is no `$"..."` form.
- Process calls support the same `{<expr>}` interpolation and escape sequences as interpolated strings (see [§4.2](#42-string-literals-and-interpolation)).
- A process call is a **process expression** whenever it appears where an expression is expected (a binding's right-hand side, an argument, inside an interpolation, and so on) — including in **static** bindings at file root or in a group body. A process call standing on its own as a task statement is a **process statement** instead ([§6.4](#64-process-calls)).
- A process expression has type `string`.

**Defaults:**

| Aspect | Behavior |
|--------|----------|
| Echo | None — the command is not echoed |
| stdout | **Captured** — becomes the value of the expression |
| stderr | Inherited — shown on the terminal as the command runs |
| stdin | Empty — the command reads end-of-file immediately and never waits for input |
| Non-zero exit status | Aborts execution with an error |
| `@status_code()` | Updated with the command's exit status |

**Trailing newlines:** every newline (`\n`, or `\r\n`) at the **end** of the captured output is removed. Nothing else is trimmed: leading whitespace, trailing spaces and tabs, and newlines inside the output are all preserved.

**Failure handling:**

A command fails when it exits with a non-zero status. There are three ways to deal with it:

| Form | On failure |
|------|------------|
| `` $`cmd` `` | Aborts execution with an error (default) |
| `` $`cmd` fallback <expr> `` | Evaluates to `<expr>` instead ([§4.8](#48-fallback)) |
| `` $[nofail]`cmd` `` | Does not abort; evaluates to whatever the command wrote to stdout (possibly nothing), and the exit status is available through `@status_code()` |

`fallback` and `nofail` cannot be combined (compile-time error).

**Attributes:** only `nofail` is valid on a process expression. `noecho` is a compile-time error, since there is nothing to echo. See [§10.5](#105-process-attributes).

**Static bindings:** in a static binding (file root or group body) the command runs lazily on first reference, once, and the result is cached ([§3](#3-bindings)). It runs in the environment of the declaring scope ([§10.4](#104-environment-attributes)). Because every process updates `@status_code()`, that first reference can change the value `@status_code()` reports in the task that triggered it.

**Examples:**

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
```

### 4.10 Lambdas

A **lambda** is a function written as a single expression:

```
|<params>| <expr>
```

```
double := |x| x * 2
add    := |a, b| a + b
```

Parameters are comma-separated names between the bars. They have **no type annotations**. The body is one expression and extends as far to the right as possible.

**Binding.** Binding a lambda evaluates nothing; it creates a lambda value. Lambda bindings follow the ordinary rules for bindings ([§3](#3-bindings)): they may be declared at file root, in a group body or in a task body, and they are immutable. A lambda can be aliased (`twice := double`).

**Calling.** The meaning of `name(args)` depends on where it is written:

| Position | `name(...)` is |
|----------|----------------|
| Statement (a line of a task body) | a **task call** ([§7](#7-task-calls)) |
| Expression (right-hand side of `:=`, an argument, an interpolation, ...) | a **lambda call** |

- A lambda call takes positional arguments only, and their number must equal the number of parameters.
- The value of the call is the value of the body.
- To call a lambda whose body is `void` (for example one that calls `@print`) for its effect, wrap the call in parentheses so that it is an expression: `(say("hi"))`. Any other value must be used, or discarded with `_ :=` ([§6.3](#63-task-body)).

**Parameter types come from the use.** A lambda has no fixed signature. On each call the argument types become the parameter types, and the body is checked with them. For every distinct list of parameter types tasq creates one *instance* of the lambda; all uses with those types share it. The same lambda can therefore be used with different types, as long as its body is valid for each of them:

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

An error inside a body is reported when a use instantiates the lambda with types for which the body is invalid. A lambda that is never used is never analysed (see [§12](#12-planned-features)).

**Scope.** A lambda body is **lexically scoped**: it sees its own parameters and the names visible where the lambda is **written**, never the locals of whoever calls it.

```
g := |k, h| h(k)

task test {
    k := 1
    f := |a| a + k          // this k is the task's k
    @print(`{g(5, f)}`)     // 6, not 10: g's own `k` (5) is not visible inside f
}
```

Parameters follow the no-shadowing rule of bindings: a parameter cannot have the same name as a name that is already visible (compile-time error).

**Lambdas as values.** A lambda value can be bound, aliased and passed around:

```
apply := |fn, x| fn(x)

task demo {
    @print(`{apply(double, 4)}`)    // 8
}
```

It can also be passed to the built-in functions that take a lambda ([§4.7](#47-built-in-functions)). Every lambda literal has its own type; two different lambdas have different types and cannot be mixed where one type is required, for example as the items of one list.

**Limits:**

- **No recursion.** A lambda cannot call itself, directly or through other lambdas (compile-time error).
- **A lambda cannot return a lambda.** `|a| |b| a + b` is a compile-time error (`lambda cannot return a lambda`).
- A lambda body is an expression, so it cannot contain task calls or statements. Use a task for actions.
- A lambda cannot be a task or group argument ([§2.3](#23-argument-types)).

---

## 5. Settings

Settings configure global interpreter behaviour. They are declared at **file root**, and **each setting may only be declared once across the entire file**.

### Syntax

**Single setting:**

```
set <name> = <meta_value>
```

**Boolean shorthand** — `bool` settings implicitly take the value `true` when no value is provided:

```
set <boolean-setting>
```

**Block form** — declares multiple settings in one statement:

```
set {
    <name> = <meta_value>
    <name> = <meta_value>
}
```

Block and single-setting declarations may be freely mixed, as long as no setting name is repeated.

### Platform-Conditional Settings

A platform attribute may be applied to a setting declaration to restrict it to a specific OS. See [§10.1 Platform Attributes](#101-platform-attributes).

```
[windows]
set script = ["cmd", "/C"]

[linux]
set script = ["bash", "-c"]

[macos]
set script = ["zsh", "-c"]
```

### Available Settings

| Setting | Meta Type | Description |
|---------|-----------|-------------|
| `script` | `[]string` | Command and arguments used to invoke each process call. Example: `["sh", "-c"]`. |
| `dotenv` | `bool \| string` | Whether to read a `.env` file into the environment. The boolean shorthand, `set dotenv`, enables reading the default `.env` file from `working_dir`. `set dotenv = "path/to/file"` also enables it, using `path/to/file` instead of the default. Default: `false` (not read). See [§10.4](#104-environment-attributes) for how loaded values interact with the `[env]` attribute and the pre-existing OS environment. |
| `working_dir` | `string` | Sets the working directory tasq's spawned processes run in. Also used to resolve the default `.env` path for `dotenv`. Defaults to the directory `tasq` was invoked from if not set. |

> There is no global setting to ignore process failures. A process that exits with a non-zero status aborts execution unless that particular call opts out with `nofail` ([§10.5](#105-process-attributes)) or, for a process expression, supplies a `fallback` ([§4.8](#48-fallback)).

> Additional settings will be added in future versions.

---

## 6. Tasks

Tasks are the primary executable units in tasq. Each task is a named, optionally parameterised block of instructions.

### Basic Syntax

```
task name {
    // task body
}
```

A task body is a *statement block* ([§6.3](#63-task-body)), so a body that consists of a single statement may omit its braces:

```
task name
    $`echo hello`
```

### Task with Arguments

```
task name(
    param1: argument_type,
    param2: argument_type = default_value,
) {
    // task body
}
```

**Rules:**

- Argument types use the argument type system (§2.3), not runtime types.
- Inside the body, arguments are treated as regular immutable bindings with their corresponding runtime type.
- Tasks **do not return values** and **cannot be used as expressions**.
- Default values are literals matching the argument's type.

### 6.1 Arguments

Each argument consists of an optional attribute list, an identifier, a declared type, and an optional default value:

```
task example(
    [<attributes>]
    identifier: argument_type,

    [<attributes>]
    identifier: argument_type = default_value,
) { ... }
```

See [§10.3 Modifier Attributes](#103-modifier-attributes) for all attributes applicable to arguments, and [§9 Command-Line Interface](#9-command-line-interface) for how arguments map to CLI usage.

### 6.2 Argument Ordering

An argument is **named** when it has a short name (`-x`), a long name (`--xyz`), or both — these are what a user types on the command line to identify it, as opposed to a positional argument, which is identified purely by its position. A user can control an argument's CLI names explicitly with attributes, e.g. `[short: 's', long: "long"]` (see [§10.3](#103-modifier-attributes)); otherwise they're assigned automatically (see below and [§9](#9-command-line-interface)).

Arguments in a task or group declaration must appear in the following order. Violating this order is a **compile-time semantic error**.

| Phase | Kind | Characteristics |
|-------|------|-----------------|
| 1st | **Positional** | No name attribute; no default value; only `string` and `number` types |
| 2nd | **Named required** | Has a CLI name (explicit or implicit); no default value |
| 3rd | **Named optional** | Has a CLI name (explicit or implicit); has a default value (`= <value>`) |

**Implicit naming** — an argument becomes named automatically in three cases:
- It has a default value (`= <value>`), making it named optional
- Its type is `flag`, `string_list`, or `number_list` — these types are inherently non-positional and are always named required unless a default is also provided
- It is a `group` argument — all group arguments are implicitly named required

Positional arguments cannot have a default value. This is a semantic error.

**Example showing all three phases:**

```
task deploy(
    // 1. Positional
    target: string,

    // 2. Named required (flag type — implicitly named)
    verbose: flag,

    // 3. Named optional (default value — implicitly named)
    retries: number = 3,
) { ... }
```

### 6.3 Task Body

A task body may contain any combination of the following:

| Element | Syntax |
|---------|--------|
| Binding declaration | `name := <expr>` |
| Process call | `` $`shell command` `` / `` $[attributes]`shell command` `` |
| Conditional statement | `if / else if / else` |
| Switch statement | `switch(...) { ... }` |
| For statement | `for(...) \|...\| { ... }` |
| Task call | `name(...)` / `::name(...)` / `group::name(...)` |

Internally, if a line in a task body doesn't match any of the statement forms above, the parser falls back to parsing it as a plain **expression statement** — an expression whose value is simply discarded. This is mainly what allows a built-in call like `@print(msg)` to be written on its own line without binding its result: `@print(...)` is an expression, but since its type is `void`, discarding the result is harmless.

**Discarding values:**

An expression statement whose value is not `void` (or `noreturn`) is a compile-time error (`discarded value`), because the value would be silently lost. To evaluate an expression and ignore its result on purpose, bind it to `_`:

```
_ := double(2)        // evaluated, result discarded
```

`_` is never defined as a name, so it cannot be read, and it can be used any number of times in the same scope.

**Statement blocks:**

Everywhere statements are expected — a task body, the branches of `if` / `else if` / `else`, the body of a `for`, and the body of a `switch` branch — the grammar accepts a **statement block**:

```
STMT_BLOCK := '{' STATEMENTS '}' | STATEMENT
```

A block that contains exactly one statement may therefore omit its braces. This is one general rule, not a special form of any construct: a brace-less task such as `task build $`cc main.c`` is simply a consequence of it.

### 6.4 Process Calls

A single shell process is invoked by writing a command in a backtick literal prefixed with `$`. String interpolation with `{ }` and escape sequences are supported (see [§4.2](#42-string-literals-and-interpolation)):

```
$`echo "Hello, {name}!"`
$`cargo build --release`
$`mkdir -p {output_dir}/bin`
```

Each `` $`...` `` literal is **one process invocation**. The command is run using the interpreter configured in the `script` setting, in the directory configured by the `working_dir` setting (§5), in the environment described in [§10.4](#104-environment-attributes).

**Process statement vs. process expression:**

A process call standing on its own as a statement in a task body is a **process statement**. A process call used inside an expression — for example `out := $`echo "Hello"`` — is a **process expression** ([§4.9](#49-process-expressions)). The two differ in their defaults:

| Aspect | Process statement | Process expression |
|--------|-------------------|--------------------|
| Echo | The command (after interpolation) is echoed before it runs; `noecho` disables this | None |
| stdout | Inherited | Captured as the value (`string`) |
| stderr | Inherited | Inherited |
| stdin | Inherited | Empty (end-of-file) |
| Non-zero exit status | Aborts execution with an error; `nofail` continues | Aborts execution with an error; `nofail` continues, `fallback` supplies a value |
| `@status_code()` | Updated | Updated |
| Fallback | None — a process statement has no `fallback` form | Optional (`fallback <expr>`, [§4.8](#48-fallback)) |
| Valid attributes | `nofail`, `noecho` | `nofail` |

**Failure:**

A process that exits with a non-zero status **aborts execution** and reports an error. This is the default for every process call; there is no global switch to change it. To continue past a failing command, mark that call with `nofail`; the exit status is then available through `@status_code()`.

**Example:**

```
task example {
    $`make build`                        // aborts execution if make fails
    $[nofail]`rm -f stale.lock`          // continues whatever happens
    @print(`rm exited with {@status_code()}`)
    $[noecho]`echo "this command is not echoed"`
}
```

### 6.5 Conditional Statements

`if` used as a **statement** provides conditional control flow inside a task body. Unlike the `if` expression (§4.3), branches contain blocks of statements rather than single expressions, and the `else` branch is optional.

```
if (<condition>) {
    // ...
} else if (<other_condition>) {
    // ...
} else {
    // ...
}
```

- The condition must evaluate to a `bool`.
- `else if` and `else` branches are optional.
- Multiple `else if` branches are allowed.
- The `{ }` around a branch's body may be **omitted** when the branch contains exactly one statement. This is the general *statement block* rule ([§6.3](#63-task-body)), not something specific to `if` — it applies to `for` bodies (§6.7) and `switch` branches too. For example:

  ```
  if (something) {
      @print(something)
  }
  ```

  is equivalent to:

  ```
  if (something)
      @print(something)
  ```

### 6.6 Switch Statement

`switch` used as a **statement** provides multi-way control flow inside a task body, matching a subject against a series of patterns.

```
switch(<subject>) {
    <pattern> => <body>,
    <pattern> => <body>,
    else => <body>,
}
```

Where `<body>` is either a single statement or a block of statements enclosed in `{ }`:

```
<pattern> => <statement>,
<pattern> => {
    <statement>
    <statement>
    ...
},
```

**Rules:**

- Used as a statement, `switch` does not produce a value and cannot appear inside an expression.
- `<subject>` is evaluated once. As with the `switch` expression (§4.4), the patterns are hashed into a lookup table at compile time and the subject's value is used as a key to jump directly to the matching branch, rather than being tested against each pattern in turn — so every pattern in a given `switch` must be unique, or it's a compile-time error.
- The `else` branch is **optional**. If no pattern matches the subject and no `else` branch is present, execution simply continues after the `switch`.

**Example:**

```
switch(color) {
    "red" => {
        $`echo "warm color"`
    },
    "blue" => $`echo "cool color"`,
    else => @error("Invalid color"),
}
```

### 6.7 For Statement

`for` used as a **statement** iterates over one or more lists in lock-step, running a block of statements for each element. Unlike the `for` expression (§4.5), it produces no value.

```
for(<subjects>) |<captures>| <stmt_block>
```

**Rules:**

- `<subjects>` is one or more comma-separated list-valued expressions, iterated in lock-step. If the subjects don't all have the same length, iteration runs only for the length of the **shortest** one — there is no out-of-bounds access and no error; the extra elements of longer subjects are simply never visited.
- `<captures>` binds an identifier to the current element of each corresponding subject, in order — use `_` to ignore a given subject's element. The number of captures must equal the number of subjects, **or** the number of subjects **+ 1**, in which case the extra, final capture is bound to the current 0-based iteration index as a `number`.
- `<stmt_block>` is either a block of statements in `{ }`, or (per the statement block rule in [§6.3](#63-task-body)) a single statement.
- `break` and `continue` (§4.6) can be used inside `<stmt_block>` — including from within a nested `if` or `switch` — to control iteration.

**Example:**

```
words   := ["one", "two", "three"]
numbers := [1, 2, 3]

for(words, numbers) |w, n| {
    @print(`{n} = {w}`)
}
```

**Example with index capture:**

```
for(words) |w, i| {
    @print(`{i}: {w}`)
}
```

**Example with mismatched lengths:**

```
// array1: 5 elements, array2: 10 elements, array3: 4 elements
for(array1, array2, array3) |_, _, _, idx| {
    @print(`{idx}`)
}
// output: 0, 1, 2, 3  (4 iterations — bounded by the shortest subject, array3)
```

### 6.8 Task Dependencies

A task can list other tasks that must run before its body. Dependencies are written as a bracketed list of **task calls**, placed between the task's argument list (if it has one) and its body:

```
task name(arg: string) [dep_a(), dep_b("x")] {
    // body
}

task other [dep_a()] {
    // body
}
```

**Rules:**

- Each entry is an ordinary task call ([§7](#7-task-calls)): the same scope resolution (`name(...)`, `::name(...)`, `group::name(...)`), the same argument passing and the same compile-time call errors apply.
- Dependencies run before the task's body, in the order they are listed.
- A dependency's arguments are ordinary expressions and may use the task's **own arguments**, e.g. `[compile(target)]` for a task that declares `target`.
- The task's `[env]` attributes ([§10.4](#104-environment-attributes)) **apply to its dependencies**: they run in the task's effective environment, exactly as if the task had called them itself.
- The list sits after the signature, so it is never confused with an attribute list ([§10](#10-attributes)), which is written before the `task` keyword.
- Since a task body is a statement block ([§6.3](#63-task-body)), a task with dependencies may also have a brace-less body.

**Example** (arguments and environment passed to a dependency):

```
task compile(target: string) {
    $`cc main.c $CFLAGS -o {target}`
}

[env: ("CFLAGS", "-O2")]
task package(target: string) [compile(target)]
    $`tar czf {target}.tgz {target}`
```

Here `compile` receives `package`'s `target` and runs with `CFLAGS=-O2`.

**Example** (a Justfile-style project):

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

---

## 7. Task Calls

Tasks can be called from within other task bodies. Task calls are **statements** — they do not produce a value and cannot appear inside expressions. (`name(...)` written in expression position is a lambda call instead, see [§4.10](#410-lambdas).)

### Scope Resolution

| Syntax | Resolves to |
|--------|-------------|
| `name(...)` | The nearest enclosing scope that defines `name` |
| `::name(...)` | The file root scope |
| `group_name::name(...)` | A specific named group |

### Argument Passing

Arguments can be passed **positionally** (in declared order) or **by name** (using the argument's identifier, regardless of order), and the two styles can be mixed within a single call as long as any positional arguments come first:

```
// Positional
compile("main.rs", 4)

// By name
compile(
    target: "main.rs",
    jobs: 4,
)

// Mixed — positional first, then named
compile("main.rs", jobs: 4)
```

**Important:** Names in task calls are the **argument identifier names** as declared in the task signature — not the `[long]` or `[short]` CLI names.

When calling a task that belongs to a group from outside that group, the group's shared arguments must also be passed by their identifier name. A task called from inside its own group may omit them — see [§8.1](#81-named-groups).

### Call Errors

The following are compile-time errors:

| Mistake | Example |
|---------|---------|
| Unknown task, group or argument name | `compil("main.rs")` |
| A positional argument after a named one | `compile(jobs: 4, "main.rs")` |
| More positional arguments than the task declares | `compile("main.rs", 4, true, "extra")` |
| The same argument supplied twice (by position and by name, or twice by name) | `compile("main.rs", target: "other.rs")` |
| An argument whose value has the wrong type | `compile(42)` for a `string` argument |
| A required argument that is not supplied (except a group's shared arguments in a call from inside the same group, [§8.1](#81-named-groups)) | `compile()` |

An argument that declares a default value (including `flag`, whose implicit default is `false`) may be omitted.

---

## 8. Groups

Groups are containers for related tasks that share a common set of arguments across all tasks inside them.

### 8.1 Named Groups

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

- Groups **cannot be nested** inside other groups.
- Group arguments are **promoted to named** — they implicitly receive CLI names following the same rules as non-positional argument types.
- Group arguments are shared across every task defined inside the group.
- Tasks in a named group are called from outside using `group_name::task_name(...)`.

**Calling tasks within a named group:**

```
// From outside the group: the group's shared arguments must be passed
some_group::some_task("positional_arg", shared_val: true)

// From inside the same group, by plain name: the shared arguments are
// already provided by the caller, so they may be omitted...
some_task("positional_arg")

// ...or passed explicitly, which overrides them for this call only
some_task("positional_arg", shared_val: false)
```

When a task calls another task of its own group, the callee receives the same values for the group's shared arguments as the caller has. Passing one by name replaces that value for the duration of that call.

### 8.2 Anonymous Groups

An anonymous group works identically to a named group but without an identifier. Its shared arguments are treated as if they were declared in the root scope.

```
group(
    shared_arg: argument_type,
) {
    task task_a { ... }
    task task_b { ... }
}
```

```
// Anonymous group with no arguments
group {
    task task_a { ... }
    task task_b { ... }
}
```

**Rules:**

- Anonymous groups cannot be targeted by the `group_name::` scope resolution syntax.
- The same no-nesting rule applies: anonymous groups cannot be placed inside another group.

---

## 9. Command-Line Interface

This section describes how task arguments map to command-line usage.

### Positional Arguments

Positional arguments are passed by position, in the order they are declared in the task signature. Only `string` and `number` may be positional.

```
tasq task_name value1 value2
```

### Named Arguments

Named arguments are identified on the command line by a long name (`--name`) or a short name (`-n`). Any argument type can be named.

```
tasq task_name --output ./dist -j 4
```

### Flags

`flag` arguments take **no value** on the command line. Their presence sets the argument to `true`; absence leaves it at the implicit default `false`.

```
tasq task_name --verbose
tasq task_name -v
```

### Implicit CLI Names

Non-positional types (`string_list`, `number_list`, `flag`) automatically receive CLI names derived from their identifier:

| Implicit attribute | Default value |
|-------------------|---------------|
| `[short]` | First letter of the argument identifier |
| `[long]` | The full argument identifier |

These can be overridden or removed with explicit `[long]` and `[short]` attributes:

```
task example(
    [long: "tag", short: 't']  // custom names
    tags: string_list,

    [short: null]               // remove short; keep long (--verbose)
    verbose: flag,

    [long: null, short: 'x']   // remove long; custom short (-x)
    extra: flag,
) { ... }
```

### Mixing Positional and Named

When a task has both positional and named arguments, positional arguments are consumed first in declaration order. Named arguments may appear anywhere in the command.

---

## 10. Attributes

Attributes annotate language elements to affect compilation, documentation, CLI naming, runtime validation, or process behavior. They are placed **directly before** the element they apply to:

```
[attribute_name]
[attribute_name: <meta_value>]
```

Multiple attributes may be written in a single bracket pair, comma-separated:

```
[int, min: 0, max: 100, desc: "A percentage value"]
```

Or across multiple bracket pairs (equivalent):

```
[int]
[min: 0, max: 100]
[desc: "A percentage value"]
```

**Process calls** are the one exception to the placement rule: because a process call is an expression, its attributes are written inline between the `$` and the backtick literal, in a single bracket pair, comma-separated: `` $[nofail, noecho]`cmd` ``. See [§10.5](#105-process-attributes).

All attribute values use **meta types** — they are compile-time literals.

**Uniqueness:**

Whether an attribute may be repeated is a **property of the attribute itself**. Every attribute is either:

- **Unique** — it may be applied **at most once** per element (once per argument, task, group, setting, or process call). Applying a unique attribute twice to the same element is a compile-time error.
- **Repeatable** — it may be applied multiple times to the same element.

Each attribute table in this section has a **Unique** column stating which of the two an attribute is.

---

### 10.1 Platform Attributes

Platform attributes restrict the annotated element to a specific operating system. Elements with no platform attribute apply to **all platforms**.

| Attribute | Platform | Unique |
|-----------|----------|:------:|
| `[windows]` | Windows | Yes |
| `[linux]` | Linux | Yes |
| `[macos]` | macOS | Yes |

**Valid on:** `set` declarations, `group` definitions, `task` definitions.

**Example:**

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

---

### 10.2 Documentation Attributes

| Attribute | Meta Type | Unique | Description |
|-----------|-----------|:------:|-------------|
| `[desc: "text"]` | `string` | Yes | Human-readable description displayed in help output. |
| `[private]` | *(none)* | Yes | Hides the task or group from CLI help/listing output. A private task can still be called normally — by name from another task, or directly from the command line — it is simply omitted from generated documentation. |

**Valid on:** `group` definitions, `task` definitions, task/group argument declarations. `[private]` is valid on `group` and `task` definitions only.

**Example:**

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
```

**`[private]` example:**

```
// Internal helper task — callable, but hidden from `tasq --help`
[private]
task _prepare_workspace {
    $`mkdir -p .cache/build`
}

task build {
    _prepare_workspace()
    $`cargo build --release`
}
```

---

### 10.3 Modifier Attributes

Modifier attributes control CLI naming and value validation for argument declarations. They are only valid on individual argument declarations inside tasks or groups.

#### Naming

| Attribute | Meta Type | Unique | Description |
|-----------|-----------|:------:|-------------|
| `[long]` | *(none)* | Yes | Use the argument identifier as the long CLI name (`--identifier`) |
| `[long: "name"]` | `string` | Yes | Use a custom string as the long CLI name |
| `[long: null]` | `null` | Yes | Remove the long CLI name entirely |
| `[short]` | *(none)* | Yes | Use the first letter of the identifier as the short CLI name (`-i`) |
| `[short: 'c']` | `char` | Yes | Use a custom character as the short CLI name |
| `[short: null]` | `null` | Yes | Remove the short CLI name entirely |

The rows above are different forms of two attributes, `long` and `short`; each of the two is unique.

#### Validation

| Attribute | Meta Type | Unique | Applicable Argument Types | Description |
|-----------|-----------|:------:|--------------------------|-------------|
| `[int]` | *(none)* | Yes | `number`, `number_list` | Require integer values only; reject floating-point input |
| `[min: n]` | `number` | Yes | `number`, `number_list` | Minimum allowed value (inclusive) |
| `[max: n]` | `number` | Yes | `number`, `number_list` | Maximum allowed value (inclusive) |
| `[pattern: "regex"]` | `string` | Yes | `string`, `string_list` | Validate each value against a regular expression |
| `[max_items: n]` | `number` | Yes | `string_list`, `number_list` | Maximum number of list items accepted |

> Additional validation attributes will be added in future versions.

**Full example:**

```
task create_user(
    // Positional
    username: string,

    // Named with validation
    [int, min: 13, max: 150, desc: "Age of the user"]
    age: number,

    // Named with custom CLI names and item limit
    [long: "tag", short: 't', max_items: 10]
    tags: string_list,

    // Optional with pattern validation
    [pattern: "^[\\w._%+\\-]+@[\\w.\\-]+\\.[a-z]{2,}$"]
    email: string = "",

    // Flag — long name kept, short removed
    [long, short: null]
    verbose: flag,
) {
    $`echo "Creating {username}, age {age}"`
}
```

---

### 10.4 Environment Attributes

Environment attributes set environment variables in a task's scope.

| Attribute | Meta Type | Unique | Description |
|-----------|-----------|:------:|-------------|
| `[env: (string,string)]` | `(string,string)` | No (repeatable) | Sets an environment variable for this task: the first tuple element is the variable name, the second is its value. May be written multiple times on the same task, once per variable, to set several environment variables at once. |

**Valid on:** `task` definitions only.

**Scope:**

- An `[env]` variable is visible to `@env(...)` calls and to spawned processes (process calls, §6.4) anywhere within the task it's declared on, including task-local bindings and process expressions. `@env(...)`, `@which(...)` (which searches the `PATH` of that environment) and spawned processes always see the same environment.
- If that task calls another task — including one listed as a dependency ([§6.8](#68-task-dependencies)) — the variable is **inherited** into the callee. It reverts once control returns back to the caller — `[env]` is scoped dynamically to the call subtree rooted at the declaring task, not a permanent, run-wide mutation. If a called task declares its own `[env]` for the same name, that value takes precedence for the duration of that call, and the earlier one resumes when it returns, following ordinary nested-scope shadowing.
- **Static bindings** (file root or group body, [§3](#3-bindings)) are evaluated once, lazily, and cached, so they never see the `[env]` of the task that happens to trigger them. They are evaluated in the environment of the scope they are declared in: the `.env` file (if enabled) and the OS environment.
- **Task-local bindings** are evaluated while the task runs and see that task's effective environment: its own `[env]` plus whatever it inherited.

**Precedence:**

When the same environment variable name could come from more than one source, tasq resolves it in this order, most specific first:

1. `[env: (...)]` attributes in effect at the current point in the call chain (above)
2. Values loaded from a `.env` file, if the `dotenv` setting (§5) is enabled
3. The pre-existing OS environment

Static bindings start at step 2, since no `[env]` is in effect for them.

**Example:**

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

### 10.5 Process Attributes

Process attributes change how a single process call behaves. They are written inline, between the `$` and the backtick literal, in one bracket pair:

```
$[nofail]`rm -f stale.lock`
$[nofail, noecho]`probe --quiet`
```

| Attribute | Meta Type | Unique | Valid on | Description |
|-----------|-----------|:------:|----------|-------------|
| `[nofail]` | *(none)* | Yes | process statement, process expression | A non-zero exit status does not abort execution. For a statement, execution simply continues. For an expression, the value is whatever the command wrote to stdout (possibly nothing). In both cases the exit status is available through `@status_code()`. |
| `[noecho]` | *(none)* | Yes | process statement | Do not echo the command before running it. The command's own output is unaffected. |

**Rules:**

- Both are presence flags and take no value.
- Using an attribute on a process call it is not valid on (for example `noecho` on a process expression) is a compile-time error.
- `nofail` cannot be combined with `fallback` ([§4.8](#48-fallback)) on the same process expression, since a `nofail` process never fails.
- Applying the same attribute twice to one process call is a compile-time error (both attributes are unique, see [§10](#10-attributes)).

**Example:**

```
task cleanup {
    $[nofail]`rm -f build.lock`
    @print(`exit status: {@status_code()}`)

    $[noecho]`echo "not echoed"`
}
```

---

## 11. Quick Reference

### Operator Summary

| Operator | Category | Operands | Result |
|----------|----------|----------|--------|
| `+` `-` `*` `/` `%` | Arithmetic | `number` | `number` |
| `>` `<` `>=` `<=` | Comparison | `number` | `bool` |
| `==` `!=` | Equality | any (matching) | `bool` |
| `and` `or` | Boolean | `bool` | `bool` |
| `!` | Negation | `bool` | `bool` |
| `-x` | Unary minus | `number` | `number` |
| `[...a, b]` | List spread | `[]T` + `T` items | `[]T` |

### Literal Summary

| Literal | Type | Interpolation | Notes |
|---------|------|:-------------:|-------|
| `"text"` | `string` | No | Basic string |
| `` `text {expr}` `` | `string` | Yes (`{ }`) | Interpolated string |
| `'c'` | `char` | No | Single character |
| `\|a, b\| expr` | lambda | No | Single-expression function; types inferred per use ([§4.10](#410-lambdas)) |
| `` $`command {expr}` `` | process call | Yes (`{ }`) | Statement: echoed, stdout and stderr inherited. Expression: not echoed, yields stdout as `string` with trailing newlines removed |

Escape sequences (valid in every literal): `\n` `\t` `\r` `\\` `\"` `\'` ``\` `` `\0` `\xNN` `\u{NNNN...}` `\{` `\}`

### Process Call Summary

| | Statement | Expression |
|---|-----------|------------|
| Echo | yes (`noecho` disables) | no |
| stdout | inherited | captured (`string`) |
| stderr | inherited | inherited |
| stdin | inherited | empty |
| On non-zero exit | abort (`nofail` continues) | abort (`nofail` continues; `fallback` supplies a value) |
| `@status_code()` | updated | updated |
| `fallback` | none | optional |
| Attributes | `nofail`, `noecho` | `nofail` |

### Scope Resolution Summary

| Syntax | Resolves to |
|--------|-------------|
| `name(...)` | Nearest enclosing scope |
| `::name(...)` | File root scope |
| `group_name::name(...)` | Specific named group |

### Attribute Validity Summary

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

### Type System at a Glance

| Context | Type System Used |
|---------|-----------------|
| Binding values, expressions | Runtime types |
| Attribute values, setting values | Meta types |
| Task/group parameter declarations | Argument types |
| Inside task body (arguments as values) | Runtime types (mapped from argument types) |
| Lambda parameters and result | Runtime types, inferred per use ([§4.10](#410-lambdas)) |
| Result of a fallible built-in call | `!T`, unusable until unwrapped to `T` via `fallback` (§4.8) |

---

## 12. Planned Features

The following are reserved for future versions and not currently part of the language:

- **Additional built-in functions** — type conversion utilities and other helpers
- **Additional settings** — further interpreter configuration options
- **Additional modifier attributes** — extended argument validation
- **Isolated `@status_code()` for static bindings** — today a lazily evaluated static binding that runs a process updates `@status_code()` like any other process; this may be changed so that evaluating a static binding leaves it untouched
- **Eager evaluation of selected static bindings** — a way to force chosen static bindings to be evaluated at startup instead of on first reference
- **Configurable stdin for process expressions** — process expressions currently read an empty stdin
- **Definition-time checking of lambdas** — today a lambda body is analysed only when it is used, so a lambda that is never used is never checked. Planned: check every lambda where it is defined (unknown names, errors that do not depend on parameter types) and require that a body only uses names declared before the lambda
- **Lambda diagnostics with instantiation traces** — errors inside a lambda body should also point at the call that instantiated it and at the lambda's definition
- **Returning lambdas (closures)** — a lambda cannot return a lambda today, because lambda values do not capture their environment