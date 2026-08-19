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
   - [4.2 String Interpolation](#42-string-interpolation)
   - [4.3 If Expression](#43-if-expression)
   - [4.4 Switch Expression](#44-switch-expression)
   - [4.5 For Expression](#45-for-expression)
   - [4.6 Break and Continue Expressions](#46-break-and-continue-expressions)
   - [4.7 Built-in Functions](#47-built-in-functions)
5. [Settings](#5-settings)
6. [Tasks](#6-tasks)
   - [6.1 Arguments](#61-arguments)
   - [6.2 Argument Ordering](#62-argument-ordering)
   - [6.3 Task Body](#63-task-body)
   - [6.4 Process Calls](#64-process-calls)
   - [6.5 Conditional Statements](#65-conditional-statements)
   - [6.6 Switch Statement](#66-switch-statement)
   - [6.7 For Statement](#67-for-statement)
7. [Task Calls](#7-task-calls)
8. [Groups](#8-groups)
   - [8.1 Named Groups](#81-named-groups)
   - [8.2 Anonymous Groups](#82-anonymous-groups)
9. [Command-Line Interface](#9-command-line-interface)
10. [Attributes](#10-attributes)
    - [10.1 Platform Attributes](#101-platform-attributes)
    - [10.2 Documentation Attributes](#102-documentation-attributes)
    - [10.3 Modifier Attributes](#103-modifier-attributes)
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
| `string` | UTF-8 text value | `"hello"` |
| `list[T]` | Homogeneous ordered collection of type `T` | `[1, 2, 3]`, `[[1,2],[3,4]]` |
| `lambda` | An anonymous, inline function value | `\|a, b\| a > b` |
| `void` | The "no meaningful value" result of certain built-in functions | *(none — cannot be written as a literal)* |
| `noreturn` | Special type given to a built-in function call, or to `break`/`continue`, that never produces a value (it always diverges) | *(none — cannot be written as a literal)* |

**Rules:**

- There is **no implicit type casting**. Use built-in functions for any conversion.
- All binding types are **inferred** from the assigned expression. No explicit type annotation is written for bindings.
- `list[T]` may be **nested** — `T` can itself be a list type (e.g. `list[list[number]]`). All elements must share the same type.
- A `list[T]` literal must **not be empty** at a point where its element type cannot be determined from context, since `T` cannot be inferred from an empty literal.
- A `lambda` literal has the form `|<captures>| <expr>` (see [§4.7](#47-built-in-functions) for the notation used to describe a lambda's parameter and return types, e.g. `|T| -> bool`). A lambda's parameter types and return type are **inferred entirely from the context that expects it** — a lambda literal has no meaning on its own. Currently the only such context is a built-in function parameter declared to accept a lambda (e.g. `@any`). A lambda literal cannot be assigned to a binding, stored in a list, or used anywhere its expected type isn't already known.
- `void` has no literal and cannot be produced directly — it only ever appears as the return type of certain built-in functions (e.g. `@print`). Unlike `noreturn`, `void` **is** a real value and behaves as an ordinary concrete type: it can be assigned to a binding, and two `void`-typed branches unify with each other in `if`/`switch`/`for` — but a `void` branch does **not** unify with a differently-typed branch. Pairing a `void` branch with, say, a `string` branch is a type error.
- `noreturn` can never be assigned to a binding directly and has no literal form. It only ever appears as the return type of certain built-in functions ([§4.7](#47-built-in-functions)) or the `break`/`continue` expressions ([§4.6](#46-break-and-continue-expressions)). When a `noreturn`-typed branch appears alongside other branches — in an `if` expression ([§4.3](#43-if-expression)), `switch` expression ([§4.4](#44-switch-expression)), or `for` expression ([§4.5](#45-for-expression)) — it unifies with whatever type the other branches produce, since a diverging branch never actually yields a value to compare. If **every** branch is `noreturn`, the expression as a whole is `noreturn`.

### 2.2 Meta Types

Meta types are used exclusively in **attribute values** and **setting values**. They are always **compile-time literals** — no expressions, variables, built-in calls, or interpolation of any kind are allowed.

| Type | Description | Literal Example |
|------|-------------|-----------------|
| `null` | Absence of a value | `null` |
| `bool` | Boolean | `true`, `false` |
| `char` | A single character | `'a'` |
| `number` | Numeric value | `16` |
| `string` | Text | `"bash"` |
| `list[T]` | Homogeneous list | `["bash", "-c"]` |

Meta type `list[T]` may be **empty** (`[]`) because the expected element type is always known from the consuming setting or attribute definition.

### 2.3 Argument Types

Argument types are used in task and group parameter declarations. They are a restricted subset of runtime types, because command-line input has to be representable as plain text tokens — a nested list or a lambda has no sensible textual form on the command line.

| Argument Type | Runtime Type | Positional? | Notes |
|---------------|--------------|:-----------:|-------|
| `string` | `string` | ✓ | |
| `number` | `number` | ✓ | Constrain to integers with `[int]` |
| `string_list` | `list[string]` | | |
| `number_list` | `list[number]` | | |
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

**Evaluation order:**

- Bindings declared in a **static context** (file root scope or group body) are evaluated **lazily** — only when first referenced, not necessarily in the order they're written.
- Bindings declared inside a **task body** are evaluated **eagerly, in statement order**, like any other statement in the task.

One practical consequence: a static binding whose expression would diverge (e.g. it calls `@error(...)`, see [§4.7](#47-built-in-functions)) only does so if something actually ends up referencing it. An unused static binding's expression is never evaluated.

**Examples:**

```
// Root scope bindings
base_port := 8080
host      := "localhost"
debug     := false
tags      := ["release", "stable"]
matrix    := [[1, 2], [3, 4]]

task example {
    // Task scope bindings
    prefix    := "build-"
    full_name := prefix + "output"
    `echo {{full_name}}`
}
```

---

## 4. Expressions

Expressions produce a typed value. They are used in binding declarations, task call arguments, conditional conditions, and inside string interpolation.

### 4.1 Operators

| Category | Operators | Operand Type(s) | Result Type |
|----------|-----------|-----------------|-------------|
| Arithmetic | `+` `-` `*` `/` | `number` | `number` |
| Comparison | `>` `<` `>=` `<=` | `number` | `bool` |
| Equality | `==` `!=` | any matching type | `bool` |
| Boolean | `and` `or` | `bool` | `bool` |
| Boolean negation | `!` | `bool` | `bool` |
| Unary minus | `-<expr>` | `number` | `number` |
| List spread | `[...list, item, ...]` | list: `list[T]`, items: `T` | `list[T]` |

**Rules:**

- There is **no implicit type coercion**. Operands must match the expected types exactly.
- Precedence follows standard mathematical convention (`*` and `/` before `+` and `-`). Boolean operators have lower precedence than comparisons.

**List spread example:**

```
base  := [1, 2, 3]
extra := [...base, 4, 5]  // [1, 2, 3, 4, 5]
```

### 4.2 String Interpolation

Inside `string` literals and backtick process calls, any expression may be embedded using double curly braces:

```
"text {{<expression>}} text"
`command {{<expression>}}`
```

The embedded expression is evaluated at runtime and converted to its string representation.

**Examples:**

```
greeting := "Hello, {{name}}!"
url      := "http://{{host}}:{{base_port + 1}}"

`echo "Running on {{@os()}} with {{worker_count}} workers"`
`mkdir -p {{output_dir}}/{{@env("BUILD_ID", "local")}}`
```

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

`for` can be used as an expression that maps, filters, or otherwise processes one or more lists in lock-step, producing a new list. Because the result is always a list, a `for` expression is written **inside square brackets**:

```
[for(<subjects>) |<captures>| <expr>]
```

**Rules:**

- `<subjects>` is one or more comma-separated list-valued expressions, iterated in lock-step. If the subjects don't all have the same length, iteration runs only for the length of the **shortest** one — no error is raised (see [§6.7](#67-for-statement) for an example).
- `<captures>` binds an identifier to the current element of each corresponding subject, in order. Use `_` for a capture whose value isn't needed. The number of captures must equal the number of subjects, **or** the number of subjects **+ 1** — the extra, final capture receives the current 0-based iteration index as a `number` (see [§6.7](#67-for-statement)).
- `<expr>` is evaluated once per iteration; its result becomes the corresponding element of the produced list. The overall result type is `list[T]`, where `T` is the type of `<expr>`.
- `<expr>` may itself be an `if` or `switch` expression containing `break` or `continue` branches (both `noreturn` — see [§4.6](#46-break-and-continue-expressions)); such branches unify with whatever type the surviving branches produce, exactly as with `@error(...)`.

**Example:**

```
input := [1, 2, 3]

doubled := [for(input) |i| i * 2]

@print("{{doubled}}") // "[2, 4, 6]"
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
    @print("{{n}}")
}
```

```
positives := [for(numbers) |n| if (n < 0) continue else n]
```

### 4.7 Built-in Functions

Built-in functions are called with an `@` prefix and may appear inside any expression.

| Signature | Return Type | Description |
|-----------|-------------|-------------|
| `@env(name: string, default: string)` | `string` | Returns the value of environment variable `name`, or `default` if it is not set. |
| `@exists(path: string)` | `bool` | Returns `true` if a file or directory exists at `path`. |
| `@os()` | `string` | Returns the current platform: `"windows"`, `"linux"`, or `"macos"`. |
| `@status_code()` | `number` | Returns the exit status of the most recently executed process. Errors if no process has been run yet in the current task. |
| `@error(message: string)` | `noreturn` | Immediately aborts execution and reports `message`. Never produces a value; see [§2.1](#21-runtime-types) for how a `noreturn` branch unifies with other branches in `if`/`switch`/`for` expressions. |
| `@print(message: string)` | `void` | Prints `message`. Because its return type is `void`, `@print(...)` can be used directly as a statement without binding its result (see [§6.3](#63-task-body)). |
| `@any(array: list[T], predicate: \|T\| -> bool)` | `bool` | Returns `true` if `predicate` evaluates to `true` for at least one element of `array`, otherwise `false`. `predicate` is a lambda literal (see [§2.1](#21-runtime-types)); `\|T\| -> bool` denotes "a lambda taking one `T` and returning `bool`". |

> Additional built-in functions will be added in future versions.

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
| `script` | `list[string]` | Command and arguments used to invoke each backtick process call. Example: `["sh", "-c"]`. |

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

An argument is **named** when it has a short name (`-x`), a long name (`--xyz`), or both — these are what a user types on the command line to identify it, as opposed to a positional argument, which is identified purely by its position. A user can control an argument's CLI names explicitly with attributes, e.g. `[short: 's', long: 'long']` (see [§10.3](#103-modifier-attributes)); otherwise they're assigned automatically (see below and [§9](#9-command-line-interface)).

Arguments in a task or group declaration must appear in the following order. Violating this order is a **compile-time semantic error**.

| Phase | Kind | Characteristics |
|-------|------|-----------------|
| 1st | **Positional** | No name attribute; no default value; only `string` and `number` types |
| 2nd | **Named required** | Has a CLI name (explicit or implicit); no default value |
| 3rd | **Named optional** | Has a CLI name (explicit or implicit); has a default value (`= <value>`) |

**Implicit naming** — an argument becomes named automatically in two cases:
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
| Process call | `` `shell command` `` |
| Conditional statement | `if / else if / else` |
| Switch statement | `switch(...) { ... }` |
| For statement | `for(...) \|...\| { ... }` |
| Task call | `name(...)` / `::name(...)` / `group::name(...)` |

Internally, if a line in a task body doesn't match any of the statement forms above, the parser falls back to parsing it as a plain **expression statement** — an expression whose value is simply discarded. This is mainly what allows a built-in call like `@print(msg)` to be written on its own line without binding its result: `@print(...)` is an expression, but since its type is `void`, discarding the result is harmless.

### 6.4 Process Calls

A single shell process is invoked by enclosing a command in backticks. String interpolation with `{{ }}` is supported:

```
`echo "Hello, {{name}}!"`
`cargo build --release`
`mkdir -p {{output_dir}}/bin`
```

Each backtick block is **one process invocation**. The command is run using the interpreter configured in the `script` setting.

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
- The `{ }` around a branch's body may be **omitted** when the branch contains exactly one statement. This shorthand applies wherever a statement block is expected — including `for` statement bodies (§6.7) — not just `if`. For example:

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
        `echo "warm color"`
    },
    "blue" => `echo "cool color"`,
    else => @error("Invalid color"),
}
```

### 6.7 For Statement

`for` used as a **statement** iterates over one or more lists in lock-step, running a block of statements for each element. Unlike the `for` expression (§4.5), it produces no value and is not wrapped in `[ ]`.

```
for(<subjects>) |<captures>| <stmt_block>
```

**Rules:**

- `<subjects>` is one or more comma-separated list-valued expressions, iterated in lock-step. If the subjects don't all have the same length, iteration runs only for the length of the **shortest** one — there is no out-of-bounds access and no error; the extra elements of longer subjects are simply never visited.
- `<captures>` binds an identifier to the current element of each corresponding subject, in order — use `_` to ignore a given subject's element. The number of captures must equal the number of subjects, **or** the number of subjects **+ 1**, in which case the extra, final capture is bound to the current 0-based iteration index as a `number`.
- `<stmt_block>` is either a block of statements in `{ }`, or (per the shorthand in §6.5) a single statement.
- `break` and `continue` (§4.6) can be used inside `<stmt_block>` — including from within a nested `if` or `switch` — to control iteration.

**Example:**

```
words   := ["one", "two", "three"]
numbers := [1, 2, 3]

for(words, numbers) |w, n| {
    @print("{{n}} = {{w}}")
}
```

**Example with index capture:**

```
for(words) |w, i| {
    @print("{{i}}: {{w}}")
}
```

**Example with mismatched lengths:**

```
// array1: 5 elements, array2: 10 elements, array3: 4 elements
for(array1, array2, array3) |_, _, _, idx| {
    @print("{{idx}}")
}
// output: 0, 1, 2, 3  (4 iterations — bounded by the shortest subject, array3)
```

---

## 7. Task Calls

Tasks can be called from within other task bodies. Task calls are **statements** — they do not produce a value and cannot appear inside expressions.

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

When calling a task that belongs to a group, the group's shared arguments must also be passed by their identifier name.

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
// From outside the group
some_group::some_task("positional_arg", shared_val: true)

// From inside the same group
some_task("positional_arg", shared_val: true)
```

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

Attributes annotate language elements to affect compilation, documentation, CLI naming, or runtime validation. They are placed **directly before** the element they apply to:

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

All attribute values use **meta types** — they are compile-time literals.

---

### 10.1 Platform Attributes

Platform attributes restrict the annotated element to a specific operating system. Elements with no platform attribute apply to **all platforms**.

| Attribute | Platform |
|-----------|----------|
| `[windows]` | Windows |
| `[linux]` | Linux |
| `[macos]` | macOS |

**Valid on:** `set` declarations, `group` definitions, `task` definitions.

**Example:**

```
[windows]
task open {
    `start https://example.com`
}

[linux]
task open {
    `xdg-open https://example.com`
}

[macos]
task open {
    `open https://example.com`
}
```

---

### 10.2 Documentation Attributes

| Attribute | Meta Type | Description |
|-----------|-----------|-------------|
| `[desc: "text"]` | `string` | Human-readable description displayed in help output. |
| `[private]` | *(none)* | Hides the task or group from CLI help/listing output. A private task can still be called normally — by name from another task, or directly from the command line — it is simply omitted from generated documentation. |

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
    `cargo build --release --jobs {{jobs}} --target {{target}}`
}
```

**`[private]` example:**

```
// Internal helper task — callable, but hidden from `tasq --help`
[private]
task _prepare_workspace {
    `mkdir -p .cache/build`
}

task build {
    _prepare_workspace()
    `cargo build --release`
}
```

---

### 10.3 Modifier Attributes

Modifier attributes control CLI naming and value validation for argument declarations. They are only valid on individual argument declarations inside tasks or groups.

#### Naming

| Attribute | Meta Type | Description |
|-----------|-----------|-------------|
| `[long]` | *(none)* | Use the argument identifier as the long CLI name (`--identifier`) |
| `[long: "name"]` | `string` | Use a custom string as the long CLI name |
| `[long: null]` | `null` | Remove the long CLI name entirely |
| `[short]` | *(none)* | Use the first letter of the identifier as the short CLI name (`-i`) |
| `[short: 'c']` | `char` | Use a custom character as the short CLI name |
| `[short: null]` | `null` | Remove the short CLI name entirely |

#### Validation

| Attribute | Meta Type | Applicable Argument Types | Description |
|-----------|-----------|--------------------------|-------------|
| `[int]` | *(none)* | `number`, `number_list` | Require integer values only; reject floating-point input |
| `[min: n]` | `number` | `number`, `number_list` | Minimum allowed value (inclusive) |
| `[max: n]` | `number` | `number`, `number_list` | Maximum allowed value (inclusive) |
| `[pattern: "regex"]` | `string` | `string`, `string_list` | Validate each value against a regular expression |
| `[max_items: n]` | `number` | `string_list`, `number_list` | Maximum number of list items accepted |

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
    `echo "Creating {{username}}, age {{age}}"`
}
```

---

## 11. Quick Reference

### Operator Summary

| Operator | Category | Operands | Result |
|----------|----------|----------|--------|
| `+` `-` `*` `/` | Arithmetic | `number` | `number` |
| `>` `<` `>=` `<=` | Comparison | `number` | `bool` |
| `==` `!=` | Equality | any (matching) | `bool` |
| `and` `or` | Boolean | `bool` | `bool` |
| `!` | Negation | `bool` | `bool` |
| `-x` | Unary minus | `number` | `number` |
| `[...a, b]` | List spread | `list[T]` + `T` items | `list[T]` |

### Scope Resolution Summary

| Syntax | Resolves to |
|--------|-------------|
| `name(...)` | Nearest enclosing scope |
| `::name(...)` | File root scope |
| `group_name::name(...)` | Specific named group |

### Attribute Validity Summary

| Attribute | `task` | `group` | argument | `set` |
|-----------|:------:|:-------:|:--------:|:-----:|
| `[windows]` `[linux]` `[macos]` | ✓ | ✓ | | ✓ |
| `[desc]` | ✓ | ✓ | ✓ | |
| `[private]` | ✓ | ✓ | | |
| `[long]` `[short]` | | | ✓ | |
| `[int]` `[min]` `[max]` `[pattern]` `[max_items]` | | | ✓ | |

### Type System at a Glance

| Context | Type System Used |
|---------|-----------------|
| Binding values, expressions | Runtime types |
| Attribute values, setting values | Meta types |
| Task/group parameter declarations | Argument types |
| Inside task body (arguments as values) | Runtime types (mapped from argument types) |
| Built-in function parameters declared as lambda | Runtime types, restricted to a `lambda` literal — the only context where a lambda literal is valid (§2.1) |

---

## 12. Planned Features

The following are reserved for future versions and not currently part of the language:

- **Additional built-in functions** — type conversion utilities and other helpers
- **Additional settings** — further interpreter configuration options
- **Additional modifier attributes** — extended argument validation