# tasq Language Specification

> **tasq** is a task runner language and interpreter designed as a modern, expressive replacement for limited task definition formats such as Justfile and Taskfile.
>
> **Status:** v0.1.0-beta. The language is feature-rich but may still change before v0.1.0.

---

## Table of Contents

1. [File Layout](#1-file-layout)
   - [1.1 Reserved Words](#11-reserved-words)
   - [1.2 Comments and Layout](#12-comments-and-layout)
   - [1.3 Namespaces](#13-namespaces)
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
   - [4.7 Try and Catch](#47-try-and-catch)
   - [4.8 Lambdas](#48-lambdas)
   - [4.9 Ranges and Slices](#49-ranges-and-slices)
   - [4.10 Tuples and Destructuring](#410-tuples-and-destructuring)
   - [4.11 In Expression](#411-in-expression)
   - [4.12 Block Expression](#412-block-expression)
5. [Built-in Functions](#5-built-in-functions)
6. [Process Calls](#6-process-calls)
   - [6.1 Statements and Expressions](#61-statements-and-expressions)
   - [6.2 Failure Handling](#62-failure-handling)
   - [6.3 Process Attributes](#63-process-attributes)
   - [6.4 Scripts](#64-scripts)
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
    - [11.4 CLI Names](#114-cli-names)
    - [11.5 Listing Tasks and Showing Usage](#115-listing-tasks-and-showing-usage)
    - [11.6 Choosing the File and Option Placement](#116-choosing-the-file-and-option-placement)
12. [Attributes](#12-attributes)
    - [12.1 Platform Attributes](#121-platform-attributes)
    - [12.2 Documentation Attributes](#122-documentation-attributes)
    - [12.3 Argument Attributes](#123-argument-attributes)
    - [12.4 Environment Attributes](#124-environment-attributes)
    - [12.5 Working Directory Attribute](#125-working-directory-attribute)
    - [12.6 Environment and Working Directory at a Glance](#126-environment-and-working-directory-at-a-glance)
13. [Parallel Execution](#13-parallel-execution)
    - [13.1 Model and Limits](#131-model-and-limits)
    - [13.2 Parallel For](#132-parallel-for)
    - [13.3 Parallel Block](#133-parallel-block)
    - [13.4 Parallel Block Expression](#134-parallel-block-expression)
    - [13.5 Failure](#135-failure)
    - [13.6 Status Code](#136-status-code)
    - [13.7 Interaction with Other Features](#137-interaction-with-other-features)
    - [13.8 Compile-Time Errors](#138-compile-time-errors)
14. [Quick Reference](#14-quick-reference)
15. [Planned Features](#15-planned-features)

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
if  else  switch  for  in  parallel
break  continue
try  catch
and  or  not
true  false
```

The name `_` is also special: it is never defined and only discards a value ([§3](#3-bindings), [§8.4](#84-task-body)).

### 1.2 Comments and Layout

- **Comments.** `//` starts a comment that runs to the end of the line. It is the only comment form; there are no block comments.
- **Trailing commas.** Wherever elements are separated by commas (list and tuple literals, task and group parameter lists, call arguments, `switch` branches, attribute lists, and so on), a trailing comma is allowed.
- **Multi-line expressions.** An expression may span several lines. There are two exceptions: the opening `[` of a slice ([§4.9](#49-ranges-and-slices)) and the opening `(` of a call must be on the same line as the end of the sliced value or of the callee. Otherwise a `[` would be read as the start of an attribute list ([§12](#12-attributes)) and a `(` as the start of a tuple, which is what lets a block expression end with a tuple ([§4.12](#412-block-expression)).

### 1.3 Namespaces

tasq has three independent namespaces:

| Namespace | Contains |
|-----------|----------|
| **Groups** | Group names |
| **Tasks** | Task names |
| **Values** | Everything that holds a value: bindings (block expressions included), task and group arguments, lambda parameters, `for` and `catch` captures, and names introduced by destructuring |

Names in different namespaces never conflict: a binding may share its name with a task, and a task may share its name with a group. Within a namespace, names must be unique within their scope, and the no-shadowing rule of [§3](#3-bindings) applies to the values namespace. Reserved words ([§1.1](#11-reserved-words)) cannot be used in any of them.

The namespaces are also why `name(...)` is unambiguous: as a statement it is looked up in the tasks namespace ([§9](#9-task-calls)), and as an expression in the values namespace, where it can only be a lambda ([§4.8](#48-lambdas)).

---

## 2. Type System

tasq uses three distinct type systems, each serving a different context. They are **not interchangeable**.

| Context | Type system |
|---------|-------------|
| Bindings and expressions (including values inside a task body, and lambda parameters and results) | Runtime types ([§2.1](#21-runtime-types), [§2.2](#22-special-types)) |
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

The types `void`, `noreturn`, results (`E!T`) and error types also exist at runtime but have no literal form; see [§2.2](#22-special-types).

**Rules:**

- There is **no implicit type casting**. Use built-in functions for any conversion.
- Binding types are **inferred** from the assigned expression. Bindings never carry a type annotation.
- `[]T` may be **nested** (e.g. `[][]number`). All elements must have the same type (result types with the same value type unify, [§2.2](#22-special-types)).
- An empty list literal `[]` is allowed wherever its element type can be inferred from the surrounding context, for example from the other branches of an `if` or `switch`; where nothing determines the type (such as `x := []`) it is a compile-time error.

  ```
  task test([long] v: flag) {
      list := if (v)
          [1, 2, 3, 4, 5]
      else
          []              // an empty []number: the type is known from the other branch
  }
  ```
- **Whole-number contexts.** Wherever a `number` is used in a place where a fractional value has no meaning (range bounds and slice bounds ([§4.9](#49-ranges-and-slices)), the position argument of `@at` ([§5](#5-built-in-functions)), the limit of `parallel` ([§13.1](#131-model-and-limits)), and any similar place), it is first **rounded up to the next whole number** (ceiling): `1.2` becomes `2`, `2.0` stays `2`, `-1.5` becomes `-1`. This is not a type conversion and never raises an error; the value is still a `number`.
- A **tuple** has at least two elements, and each element has its own type. Its type is the ordered list of its element types, so `(string, number)` and `(number, string)` are different types. An element may be a `bool`, `char`, `number`, `string`, list, tuple, `lambda` or result; it cannot be `void`, `noreturn` or an error value. Tuples may be nested and may be list elements (all elements of such a list must then have the identical tuple type). A tuple is created with a literal and taken apart by destructuring ([§4.10](#410-tuples-and-destructuring)).
- A `lambda` is a **template**: its parameter and result types are inferred from each use. Lambdas can be bound, aliased, passed around, stored in a tuple and passed to the built-ins that take a lambda. The full rules and limits are in [§4.8](#48-lambdas).

### 2.2 Special Types

These types have **no literal** and can only be produced by certain built-ins, process expressions or keywords.

| Type | Meaning | Produced by |
|------|---------|-------------|
| `void` | "No meaningful value" | Built-ins such as `@print` |
| `noreturn` | The expression never yields a value; it always diverges | `@error(...)`, `break`, `continue` |
| `E!T` | A **result**: either a `T` or an error of error type `E` | `@env`, `@which`, `@parse_number`, `@at`, `@read`, process expressions |
| `error{a, b}` | An **error type**: the set of error ids a failure can have | The capture of `catch` |

> **Notation.** `E!T` and `error{...}` are type notation only. They cannot be written in source code, and `!` is not an operator. Boolean negation is written `not` ([§4.1](#41-operators)).

**`void`** is a real value that behaves as an ordinary concrete type. It can be assigned to a binding, and two `void` branches unify with each other, but a `void` branch does **not** unify with a differently typed branch (a `void` branch paired with a `string` branch is a type error).

**`noreturn`** can never be assigned to a binding.

**Results.** A result `E!T`, for example `error{invalid_format}!number`, holds either a value of type `T` or an error whose type is `E`. `T` is any runtime type except `void`, `noreturn`, an error type or another result.

- A result is an ordinary value. It can be bound, passed to a lambda, returned from a lambda or block, stored in a list or tuple, and used in interpolation, where it shows its value, or the message of its error if it holds one ([§4.2](#42-strings-and-interpolation)).
- It becomes a plain `T` only through `try` or `catch` ([§4.7](#47-try-and-catch)). There is no implicit conversion in either direction: a result is not accepted where a `T` is expected, and a `T` is not a result.
- Results cannot be compared with `==` and cannot be the subject of a `switch`.

**Error types.** `error{id, ...}` is a non-empty set of error ids; an id is an identifier. An **error value** has two parts:

- an **id**, one of the ids of its type, which says where a failure comes from (internal, user input, environment, ...). It is what code checks, with `switch` ([§4.4](#44-switch-expression)).
- a **message** that describes exactly what happened. The same id can come with different messages. Messages are for display, not for checking.

An error value exists only as the capture of a `catch` handler ([§4.7](#47-try-and-catch)); `try` never exposes it. An error type is never a `T`, so an error value cannot appear in a result, a list or a tuple.

**Unifying branches.** `if` ([§4.3](#43-if-expression)), `switch` ([§4.4](#44-switch-expression)), `for` ([§4.5](#45-for-expression)), `in` ([§4.11](#411-in-expression)) and `catch` ([§4.7](#47-try-and-catch)) combine several branches into one result type:

- All branches must produce the same type.
- A `noreturn` branch is the exception: it never yields a value, so it unifies with whatever type the other branches produce (e.g. `@error(...)`, or `break` / `continue` inside a `for` expression).
- If **every** branch is `noreturn`, the whole expression is `noreturn`.
- Result types with the same value type `T` unify, and the error type of the unified result is the union of their error types.

### 2.3 Meta Types

Meta types are used **only** in attribute values and setting values. A meta value is always a **compile-time literal**: no expressions, variables, built-in calls or interpolation.

| Type | Description | Literal example |
|------|-------------|-----------------|
| `null` | Absence of a value | `null` |
| `bool` | Boolean | `true`, `false` |
| `char` | A single character | `'a'` |
| `number` | Numeric value | `16` |
| `string` | Text | `"bash"` or `bash` |
| `[]T` | Homogeneous list (may be empty: `[]`) | `["bash", "-c"]` |
| `(T,U,...)` | Fixed-size, heterogeneous sequence | `("some_string", 25)` |

- **Strings.** A meta `string` is either a basic `"..."` literal or a bare identifier, which is the string of the same text: `full` and `"full"` are the same value. Raw, interpolated and process forms are not allowed. `null`, `true` and `false` keep their literal meaning, and text that is not an identifier (such as `-c`) must be quoted.
- **Lists.** A meta `[]T` may be empty because the expected element type is always known from the consuming setting or attribute.
- **Tuples.** The size is fixed by the number of types listed, and each position must match its declared type exactly. Element types may be any meta type, including lists and other tuples. The tuple *type* lists types, e.g. `(string,number)`; the tuple *literal* lists values, e.g. `("some_string", 25)`. Meta tuples are unrelated to **runtime tuples** ([§4.10](#410-tuples-and-destructuring)), which are ordinary values built from expressions.
- **Unions.** A setting's type may be a union `T | U`, meaning either type is accepted. This is currently used only by the `dotenv` setting ([§7](#7-settings)).

#### Constraints

Where this specification declares an attribute or a setting, its meta type may carry **constraints** in parentheses that narrow the accepted values:

```
number(int, min = 1)           // a whole number, at least 1
string([none, name, full])     // exactly one of these three strings
[]string(min_items = 1)        // a non-empty list of strings
```

| Type | Constraint | Meaning |
|------|------------|---------|
| `number` | `int` | Only whole numbers are accepted. |
| `number` | `min = n` | The value is at least `n` (inclusive). |
| `number` | `max = n` | The value is at most `n` (inclusive). |
| `string` | `[a, b, ...]` | Only the listed strings (the *options*) are accepted. Without it any string is accepted. |
| `[]T` | `min_items = n` | The list has at least `n` elements. |
| `[]T` | `max_items = n` | The list has at most `n` elements. |

- Constraints belong to the declaration of an attribute or setting; they are not syntax that can be written in a tasq file.
- The compiler enforces them: a value that violates a constraint is a compile-time error.
- A string with options is written like any meta string, quoted or as a bare identifier. Options are compared as exact text.

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
- Tuples, lambdas and results are not argument types.

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
- Bindings may be declared at file root, in a group body, in a task body, or in a block expression ([§4.12](#412-block-expression)).
- **Unique names and no shadowing.** Within one scope, binding names must be unique, and a name cannot be declared if the same name is already visible at that point in the values namespace ([§1.3](#13-namespaces)). This *no-shadowing rule* applies equally to lambda parameters ([§4.8](#48-lambdas)), `for` and `catch` captures ([§4.5](#45-for-expression), [§4.7](#47-try-and-catch)) and the names introduced by destructuring patterns ([§4.10](#410-tuples-and-destructuring)). Violations are compile-time errors.
- Inside a task body, task arguments behave as immutable bindings of their runtime type.
- A binding named `_` is never defined; it only discards its value ([§8.4](#84-task-body)). Inside a destructuring pattern, `_` discards just that element.
- A binding is a declaration, not an expression. To name a value **inside** an expression (for example in the body of a lambda), use a block expression ([§4.12](#412-block-expression)).

**Evaluation:**

| | Static bindings (file root, group body) | Task-local bindings (task body) |
|---|---|---|
| When | **Lazily**, on first reference | **Eagerly**, in statement order |
| How often | At most once per run; the result is cached | Every time the task runs |
| Environment | The environment of the scope they are **declared in** (the `.env` file, if enabled, and the OS environment), never that of whichever task triggers them | The task's effective environment |
| Working directory | The root working directory (the `working_dir` setting, [§7](#7-settings)), never that of whichever task or `in` block triggers them | The working directory in effect at that point of the task, including any enclosing `in` ([§8.9](#89-in-statement)) |

The complete picture of which construct sees which environment and working directory is in [§12.6](#126-environment-and-working-directory-at-a-glance).

Consequences:

- A static binding whose expression would diverge (e.g. calls `@error(...)`) only does so if something references it. An unused static binding is never evaluated.
- A static binding containing a process expression ([§6](#6-process-calls)) runs its command only on first reference, and only once. This makes it a convenient place to store a value such as a tool version that several tasks need. The binding caches the process's result, so unwrap it where it is declared (`catch`, `try`) to cache a plain `string`. Because every process call updates `@status_code()` ([§5](#5-built-in-functions)), that first reference can change the value `@status_code()` reports in the task that triggered it.
- A **destructuring** static binding is one unit: referencing **any** of its names evaluates the whole right-hand side once, and every name of that binding then has its cached value.
- "At most once" also holds when several branches of a parallel construct reference the same static binding for the first time at the same moment: one of them evaluates it and the others wait for the result ([§13.7](#137-interaction-with-other-features)).

**Examples:**

```tasq
// Root scope bindings
base_port := 8080
host      := "localhost"
debug     := false
tags      := ["release", "stable"]
matrix    := [[1, 2], [3, 4]]

// Evaluated lazily, once, on first use
zig_version := $`zig --version` catch "unknown"

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
| Equality | `==` `!=` | any matching type (tuples compare element-wise, [§4.10](#410-tuples-and-destructuring); lambdas compare by template, [§4.8](#48-lambdas)); results and error values cannot be compared | `bool` |
| Boolean | `and` `or` | `bool` | `bool` |
| Boolean negation | `not <expr>` | `bool` | `bool` |
| Unary minus | `-<expr>` | `number` | `number` |
| Unwrap | `try <expr>`, `<expr> catch [\|e\|] <expr>` | result `E!T` | `T` ([§4.7](#47-try-and-catch)) |
| List spread | `[...list, item, ...]` | list `[]T`, items `T` | `[]T` |
| Range | `a..b`, `a..` | `number` | not a value; only valid as a `for` subject or a slice index ([§4.9](#49-ranges-and-slices)) |
| Slice | `value[a..b]` | `[]T` or `string`, and a range | same type as `value` ([§4.9](#49-ranges-and-slices)) |

**Rules:**

- There is **no implicit type coercion**; operands must match the expected types exactly.
- **Arithmetic precedence** follows mathematical convention (`*`, `/`, `%` before `+`, `-`). The slice postfix `[...]` binds tighter than every operator. The range operator `..` binds more loosely than every arithmetic operator, so `a + 1..b * 2` means `(a + 1)..(b * 2)`.
- **Boolean precedence**, from tightest to loosest: comparison and equality, then `not`, then `and`, then `or`. So `not a == b` means `not (a == b)`, `not a and b` means `(not a) and b`, and `a or b and c` means `a or (b and c)`. `not` may be repeated (`not not x`).
- **Unwrap precedence.** `try` is a prefix operator that binds like unary minus. `catch` is looser than every other operator ([§4.7](#47-try-and-catch)).
- There is **no `!` operator**. Boolean negation is always written `not`. The `!` of `!=` belongs to that operator only.

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

#### List spread

```
base  := [1, 2, 3]
extra := [...base, 4, 5]  // [1, 2, 3, 4, 5]
```

#### Modulo

`a % b` is the remainder of truncated division:

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

#### Literal forms

| Literal | Type | Lines | Interpolation | Escapes |
|---------|------|-------|:-------------:|:-------:|
| `"text"` | `string` | single line | no | yes |
| `r"text"` | `string` | single line | no | no (raw) |
| `` `text {<expr>}` `` | `string` | single or multiple | yes | yes |
| ``r`text` `` | `string` | single or multiple | no | no (raw) |
| `'c'` | `char` | single character | no | yes |

- **Basic string `"..."`.** Taken as written, apart from escape sequences. `{` and `}` have no special meaning. A line break inside the literal is a compile-time error.
- **Raw string `r"..."`.** Every character is taken literally, a backslash included. It cannot contain a `"`, as there is no way to escape it, and it cannot span lines.
- **Interpolated string `` `...` ``.** Any expression may be embedded using single curly braces ([Interpolation](#interpolation)). It may span lines ([Multi-line strings](#multi-line-strings)).
- **Raw backtick string ``r`...` ``.** The text is taken literally: no interpolation and no escapes, so `{`, `}` and `\` need no care. It cannot contain a backtick. It may span lines, with the same rules as an interpolated string.
- **Char `'c'`.** A single character. There is no raw form.
- `r` starts a raw string only when it is written directly in front of the opening quote or backtick; anywhere else it is an ordinary identifier.

Process calls accept a string expression of any of these forms ([§6](#6-process-calls)).

#### Multi-line strings

A backtick string (interpolated or raw) is either **single-line** or **multi-line**:

```
one_line := `one line of text`

multi := `
    first line
        an indented line
    last line
`
```

A literal that contains a line break is multi-line and must follow these rules:

1. **Layout.** The opening backtick must be followed immediately by a line break, and the last line (the one holding the closing backtick) must contain only whitespace. Otherwise it is a compile-time error.
2. **Content.** The lines between the opening line break and the closing line make up the text. They are joined with line breaks, and the text has **no leading and no trailing line break**. A trailing line break, if wanted, is written as `\n` at the end of the last content line (not possible in a raw string).
3. **Indentation.** The common indentation is the number of leading whitespace characters of the least-indented content line. It is removed from every content line, so that line starts at column 0.
   - A space and a tab each count as one character, and they may be mixed.
   - The closing line does not take part. Whitespace-only content lines are ignored when finding the common indentation and become empty lines.
4. **Order of processing.** Indentation is normalized on the source text, **before** escape sequences and interpolation are processed. Interpolated values are never re-indented, and an escape such as `\t` at the start of a line does not count as indentation.

In the examples below, `|` marks the left edge of the resulting text and is not part of it:

```
example1 := `
    multiple
       line
           text
`
//   |multiple
//   |   line
//   |       text

example2 := `
       multiple
    line
              text
`
//   |   multiple
//   |line
//   |          text
```

The least-indented line decides the common indentation, whatever its position.

#### Interpolation

In an interpolated string (`` `...` ``), `{<expression>}` is evaluated at runtime and converted to its string representation:

```
greeting := `Hello, {name}!`
url      := `http://{host}:{base_port + 1}`

$`echo "Running on {@os()} with {worker_count} workers"`
$`mkdir -p {output_dir}/{@env("BUILD_ID") catch "local"}`
```

Lists and tuples are converted by converting each element and joining them with `, `; a list is wrapped in `[` `]` and a tuple in `(` `)`, e.g. `[1, 2, 3]` and `(str, 5, false)`. Strings inside them are written without quotes. A lambda (also one inside a tuple) is written as `<lambda>`. A result is converted like its value if it holds one, and to the message of its error otherwise; an error value (inside a `catch` handler) is converted to its message.

Because `{` starts an interpolation, a literal brace in an interpolated string must be escaped (`\{`, `\}`), or the string written as a raw string, where nothing needs escaping:

```
$`awk '\{print $1\}' input.txt`      // escaped braces in an interpolated string
$r`awk '{print $1}' input.txt`       // raw string: braces and $ are taken literally
```

#### Escape sequences

Escapes are valid in every non-raw literal (`"..."`, `` `...` `` and `'c'`), even where an escape is not strictly needed (e.g. `\{` inside a basic string):

| Escape | Meaning |
|--------|---------|
| `\n` `\t` `\r` | Newline, tab, carriage return |
| `\\` | Backslash |
| `\"` `\'` ``\` `` | Double quote, single quote, backtick |
| `\0` | Null character |
| `\xNN` | Character with the two-digit hexadecimal code `NN` |
| `\u{NNNN...}` | Unicode code point given as hexadecimal digits |
| `\{` `\}` | Literal `{` / `}` (prevents interpolation) |

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
- **Patterns are literals.** A pattern may be any literal (`bool`, `char`, `number`, `string`, or a list or tuple literal), and must have the same type as the subject. Expressions are not allowed as patterns, and neither are ranges. The one exception is an error subject, below.
- **Every pattern in a `switch` must be unique**; a duplicate is a compile-time error.
- The `else` branch is **required** in expression form, since every subject value must produce a result. The one exception is an error subject whose ids are all covered, below.
- Branches are unified as described in [§2.2](#22-special-types). This is how `@error(...)` can serve as an `else` branch when there is no sensible fallback value.

```
rgb := switch(color) {
    "red"   => "#ff0000",
    "green" => "#00ff00",
    "blue"  => "#0000ff",
    else    => @error("Invalid color"),
}
```

#### Switching on an error

The subject may be an error value, available inside a `catch` handler ([§4.7](#47-try-and-catch)). The patterns are then string literals naming ids of its error type ([§2.2](#22-special-types)):

- An id that is not in the error type is a compile-time error, and so is a duplicate.
- When the patterns cover **every** id, the switch is exhaustive: `else` is not required, even in expression form. Writing one anyway is a **warning** (it can never be reached); warnings do not stop compilation ([§11.2](#112-checking-without-running---check)).
- When some ids are not covered, `else` is required in expression form, as for any other subject.

```
value := @parse_number(text) catch |err| switch(err) {
    "invalid_format" => @error(`unable to parse value: {err}`),
}
```

The statement form is described in [§8.6](#86-switch-statement).

### 4.5 For Expression

A `for` expression maps, filters or otherwise processes one or more lists (or ranges) in lock-step and produces a **new list**. It is not wrapped in brackets:

```
for(<subjects>) [parallel[(<n>)]] |<captures>| <expr>
```

- `<subjects>` are one or more comma-separated subjects, each a list expression or a range. They are iterated in lock-step over a shared window of indices. The iteration rules (window, clamping, unbounded ranges) are defined once, in [§4.9](#49-ranges-and-slices); in short, with only list subjects the loop runs for the length of the **shortest** one, with no error.
- `parallel`, when written, makes the iterations run concurrently; the result is the same list, in the same order ([§13.2](#132-parallel-for)).
- `<captures>` binds one capture to each subject, in order. A capture is an identifier (the current element of a list subject, or the current index of a range subject), `_` for a value you don't need, or a destructuring pattern `(a, b)` when the elements are tuples ([§4.10](#410-tuples-and-destructuring)). The number of captures **must equal** the number of subjects.
- `<expr>` is evaluated once per iteration, and its result becomes the corresponding element of the produced list. The result type is `[]T`, where `T` is the type of `<expr>`. If there are no iterations the result is an empty `[]T`.
- `<expr>` may be an `if`, `switch`, `in`, block ([§4.12](#412-block-expression)) or `catch` ([§4.7](#47-try-and-catch)) expression containing `break` or `continue` branches ([§4.6](#46-break-and-continue)); these are `noreturn` and unify with the surviving branches ([§2.2](#22-special-types)).
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

Both have type `noreturn` ([§2.2](#22-special-types)), so they can be used as branches of a nested `if`, `switch` or `in`, as the result of a block expression and as the handler of a `catch`.

| Keyword | In a `for` **statement** | In a `for` **expression** |
|---------|--------------------------|---------------------------|
| `break` | Stops iteration immediately. | Stops immediately and yields the list produced so far. |
| `continue` | Skips the rest of the current iteration and proceeds to the next. | Skips the current element (it is **not** added to the list) and proceeds. |

Both always refer to the **nearest enclosing `for`**; a nested `if`, `switch`, `in`, block expression or `catch` handler does not change this, and neither does an inner `for`: in nested loops, `break` and `continue` affect only the innermost one. Leaving an `in` block this way restores the previous working directory ([§4.11](#411-in-expression)).

In a **parallel** `for`, `break` is a compile-time error and `continue` works as in the table ([§13.2](#132-parallel-for)). Neither keyword can refer to a `for` that encloses a parallel block ([§13.3](#133-parallel-block)) or a branch of a parallel block expression ([§13.4](#134-parallel-block-expression)).

```
for(numbers) |n| {
    if (n < 0) continue
    if (n > 100) break
    @print(`{n}`)
}

positives := for(numbers) |n| if (n < 0) continue else n
```

### 4.7 Try and Catch

`try` and `catch` turn a result `E!T` ([§2.2](#22-special-types)) into a plain `T`. They are the only way to read the value of a result.

```
try <expr>
<expr> catch [|<capture>|] <expr>
```

**Operand.** The operand of `try`, and the left operand of `catch`, must be a result; any other type is a compile-time error. In particular, a process expression with `nofail` is a plain `string` ([§6.2](#62-failure-handling)) and cannot be unwrapped.

**`try <expr>`** evaluates to the value of the result. If the result holds an error, `try` aborts execution and prints the error's message. The error value is not accessible.

**`<expr> catch [|<capture>|] <handler>`** evaluates to the value of the result. If the result holds an error, the handler is evaluated instead, and its value is the value of the whole expression. Otherwise the handler is never evaluated.

- The handler must produce `T`, or `noreturn` (such as `@error(...)`, `break` or `continue`), which unifies with `T` ([§2.2](#22-special-types)). The whole expression has type `T`.
- The optional **capture** `|err|` binds the error value for the handler only. Its type is the error type of the result, and its name follows the no-shadowing rule ([§3](#3-bindings)). The error value can be interpolated (its message) and used as the subject of a `switch` (its id, [§4.4](#44-switch-expression)). It cannot be bound to another name, passed to a lambda, stored in a list or tuple, or compared. Since an error type is never a `T`, it cannot leave the handler either.

**`try` is shorthand.** `try x` is exactly `x catch |err| @error(`{err}`)`.

**Precedence.**

- `try` is a prefix operator that binds like unary minus: `try @read(f) + "x"` means `(try @read(f)) + "x"`.
- `catch` is looser than every other operator, and its handler extends **as far right as possible**: `@env("A") catch "b" + "c"` means `@env("A") catch ("b" + "c")`. Use parentheses to limit it: `(@env("A") catch "b") + "c"`.
- Chains nest to the right: `@env("A") catch @env("B") catch "x"` tries `A`, then `B`, then `"x"`.
- A result produced by an `if` or `switch` is unwrapped with parentheses, `(if (c) @read(a) else @read(b)) catch ""`, because the last branch would otherwise take the `catch` for itself.

```
// Plain default value
path := @env("PATH") catch ""

// Abort if PORT is not numeric, with the message of the error
port := try @parse_number(@env("PORT") catch "8080")

// ...or with a message of your own
port := @parse_number(@env("PORT") catch "8080") catch @error("PORT must be numeric")

// Require a tool to be installed
zig := @which("zig") catch @error("zig is not installed")

// Element access with a default
first := @at(names, 0) catch "none"

// File content with a default
notes := @read("NOTES.md") catch ""

// Process expression with a default
version := $`git describe --tags` catch "dev"

// Process expression that aborts with a custom message
sha := $`git rev-parse HEAD` catch |err| @error(`not a git repository: {err}`)

// React to the error id: the patterns cover every id, so no `else` is needed
text := @read(path) catch |err| switch(err) {
    "read_failed"  => "",
    "invalid_utf8" => @error(`{path} is not valid UTF-8`),
}

// A result is an ordinary value: keep it and decide later
parsed  := for(["1", "x", "3"]) |s| @parse_number(s)   // []error{invalid_format}!number
numbers := for(parsed) |r| r catch continue            // [1, 3]
@print(`{parsed}`)                                     // the element "x" shows its error message
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

Parameters are comma-separated names between the bars, with **no type annotations**. The body is one expression and extends as far right as possible. Parameters are plain names; they cannot be destructuring patterns, and they follow the no-shadowing rule ([§3](#3-bindings)).

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

**Scope.** A lambda body is **lexically scoped**: it sees its own parameters and the names visible where the lambda is **written**, never the locals of its caller. (This concerns names only; the working directory and the environment are not names, and a lambda is evaluated in the working directory and the environment in effect where it is **called**, see [§4.11](#411-in-expression) and [§12.6](#126-environment-and-working-directory-at-a-glance).)

```
g := |k, h| h(k)

task test {
    k := 1
    f := |a| a + k          // this k is the task's k
    @print(`{g(5, f)}`)     // 6, not 10: g's own `k` (5) is not visible inside f
}
```

**Lambdas as values.** A lambda can be bound, aliased, passed to other lambdas, stored in a tuple and passed to the built-ins that take a lambda ([§5](#5-built-in-functions)):

```
apply := |fn, x| fn(x)

task demo {
    @print(`{apply(double, 4)}`)    // 8
}
```

Every lambda literal has its own type, so two different lambdas cannot be mixed where a single type is required (for example as the elements of one list).

**Naming intermediate values.** A lambda body is one expression, so it cannot contain bindings directly. Use a block expression ([§4.12](#412-block-expression)) to compute a value once and use it several times:

```
average := |xs| {
    total := @reduce(xs, 0, |acc, x| acc + x)
    total / @len(xs)
}
```

**Equality and printing.** Lambdas can be compared with `==` and `!=`: two lambda values are equal when they refer to the exact same template. A lambda is converted to the string `<lambda>` in interpolation. The same holds for a tuple that contains a lambda, which is compared element-wise ([§4.10](#410-tuples-and-destructuring)). Neither is useful in practice, but both are allowed.

**Limits:**

- **No recursion.** A lambda cannot call itself, directly or through other lambdas (compile-time error).
- **A lambda cannot return a lambda**, nor a tuple that contains a lambda. `|a| |b| a + b` is a compile-time error (`lambda cannot return a lambda`). This is a deliberate part of the language, not a gap.
- A lambda body is an expression, so it cannot contain task calls or statements. Use a task for actions, and a block expression to name intermediate values.
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

This section is the single definition of how `for` iterates, for both the expression and the statement form, sequential or parallel.

Every `for` subject contributes an interval of indices, and the loop runs over the **intersection** of all of them:

| Subject | Interval | Capture receives |
|---------|----------|------------------|
| List `[]T` | `0..@len(list)` | The element at the current index |
| Range `a..b` | `a..b` | The current index, as a `number` |
| Range `a..` | `a..` (no upper end) | The current index, as a `number` |

- The loop's **window** starts at the largest start and ends at the smallest end of all intervals, and iterates one index at a time. List elements are always read at their **absolute index**, which is what makes `for(list, 0..) |item, i|` bind `i` to the element's index.
- With only list subjects the window is `0..@len(shortest)`: iteration stops at the end of the **shortest** subject, the extra elements of longer subjects are never visited, and there is no out-of-bounds access and no error.
- Because a list's interval starts at `0`, a range bound below `0` is **clamped to `0` whenever at least one subject is a list**. When **no** subject is a list, negative bounds are kept, which is useful for generating lists.
- If the window has **no finite end** (every subject is a range without a right bound), the loop runs **zero times**. A range loop can never be infinite; infinite loops do not exist in tasq.
- If the window's start is not below its end, the loop runs zero times. This is never an error.

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
- The opening `[` of a slice must be on the **same line** as the end of `value` ([§1.2](#12-comments-and-layout)).
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

It is allowed in two places:

| Place | Syntax | Notes |
|-------|--------|-------|
| Binding | `a, b := <tuple expr>` | The outermost pattern is written **without** parentheses. Nested patterns use parentheses: `label, (x, y) := <tuple expr>`. |
| `for` capture | `for(<subjects>) \|(a, b)\| ...` | A subject whose elements are tuples is captured with a parenthesized pattern. Plain captures may be mixed in: `\|(a, b), i\|`. |

**Rules:**

- The pattern's shape must match the tuple's type **exactly**: the same number of elements at every level (compile-time error otherwise), and the right-hand side must be a tuple.
- `_` discards one element. It is never defined and may appear any number of times.
- The names a pattern introduces are ordinary bindings: they are immutable and follow the uniqueness and no-shadowing rules of [§3](#3-bindings). A name bound by a `for` capture is visible only in that construct's body.
- Destructuring bindings are valid at file root, in a group body, in a task body and in a block expression. Evaluation is as in [§3](#3-bindings): task-local bindings run eagerly in statement order, and static bindings run **lazily and once**, when **any** of their names is first referenced.
- Destructuring is not available for lambda parameters, `catch` captures or task and group arguments.

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

`in` is a keyword ([§1.1](#11-reserved-words)). The statement form is described in [§8.9](#89-in-statement); the semantics below are shared by both forms.

**Evaluation:**

- `<path>` is an expression of type `string`, evaluated once, first.
- A relative path is resolved against the working directory **in effect**, so nested `in` blocks compose. An absolute path is used as is.
- The path is **valid** when it exists and is a directory. If it is valid, the working directory becomes that directory and the first expression is evaluated. If it is not valid (it does not exist, or it is a file), the `else` expression is evaluated instead, in the working directory that was in effect around the `in`.
- The `else` branch is **required** in expression form, as for `if` ([§4.3](#43-if-expression)). The branches are unified as described in [§2.2](#22-special-types), so `@error(...)` is a typical `else` branch.

```
sources := in("src") @sort(@glob("*.zig"), |a, b| a < b) else @error("src/ is missing")
```

**What the working directory affects.** Inside `in`, the new working directory is used by every process call and by the file-system built-ins and `@cwd` (the full list is in [§12.5](#125-working-directory-attribute)). `@invocation_dir` is not affected. `in` also does not touch the **environment**: the body runs in the effective environment inherited from the enclosing context ([§12.4](#124-environment-attributes)), and the `.env` file ([§7](#7-settings)) is neither re-read nor re-located.

**Inheritance and restoration:**

- The previous working directory is **restored** when the `in` is left, however that happens: normally, through `break` or `continue` ([§4.6](#46-break-and-continue)), or by an abort (`@error(...)` or a failed process).
- A task called from inside an `in` block does **not** inherit the block's directory: every task runs in its own working directory ([§12.5](#125-working-directory-attribute)), whoever calls it. This differs from `[env]`, which a callee does inherit ([§12.4](#124-environment-attributes)).
- A lambda is evaluated in the working directory (and environment) in effect **where it is called**, not where it is written ([§4.8](#48-lambdas)).
- **Static bindings** never see the working directory of whatever triggers them ([§3](#3-bindings)).
- Inside a branch of a parallel construct, `in` changes the working directory of that branch only ([§13.1](#131-model-and-limits)).

### 4.12 Block Expression

A **block expression** names intermediate values **inside a single expression**: compute a value once, then use it several times. It matters most in lambda bodies ([§4.8](#48-lambdas)), which are a single expression and cannot contain bindings directly ([§3](#3-bindings)).

```
{
    <binding>
    <binding>
    ...
    <result expression>
}
```

- **Contents.** Zero or more bindings (plain, destructuring ([§4.10](#410-tuples-and-destructuring)) or `_ :=` ([§8.4](#84-task-body))), then exactly one **result expression**, last. Nothing else may appear: a block expression has no statements, no task calls and no expression lines other than the result. To run something only for its effect, bind and discard it (`_ := @print("x")`).
- **Value.** The value and type of the block are those of its result expression. If the result expression is `noreturn`, so is the block ([§2.2](#22-special-types)).
- **Evaluation and scope.** The bindings are evaluated eagerly, in order, every time the block is evaluated; nothing is cached. A name is visible from the line after its binding to the end of the block, and nowhere else. Names follow the uniqueness and no-shadowing rules of [§3](#3-bindings).
- **Environment and directory.** A block expression does not change the working directory or the environment; unlike `in` ([§4.11](#411-in-expression)), it runs exactly as it would outside the block.
- **Jumps.** `break` and `continue` inside a block refer to the nearest enclosing `for` ([§4.6](#46-break-and-continue)).
- **Where it can be written.** Wherever an expression is expected: the right-hand side of a binding, a lambda body, a branch of `if` or `switch`, the body of a `for` expression, a `catch` handler, an argument. Where a *statement* is expected, `{ ... }` is a statement block ([§8.4](#84-task-body)) holding statements; the statement forms of `if`, `switch`, `for` and `in` take statement blocks, and their expression forms take expressions, which may be block expressions.

The parallel counterpart, where every binding is a concurrent branch, is in [§13.4](#134-parallel-block-expression).

```
// Split the line a single time
parse_repo := |line| {
    parts := @split(line, ";")
    (
        @at(parts, 0) catch @error("missing repo name"),
        @at(parts, 1) catch @error("missing repo url"),
    )
}

// A block can hold a `catch` handler and end with a `for` expression
read_repos := |file| {
    text := @read(file) catch |err| @error(`cannot read {file}: {err}`)
    for(@lines(text)) |line|
        if (line == "") continue
        else parse_repo(line)
}

// Destructuring inside a block
describe := |origin, p| {
    ox, oy := origin
    px, py := p
    `dx={px - ox} dy={py - oy}`
}

// Outside lambdas: a binding with a few steps
timeout := {
    base  := 5
    extra := if (debug) 10 else 0
    base + extra
}

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
| `@env(key: string)` | `error{not_set}!string` | Value of environment variable `key` as visible in the current scope ([§12.4](#124-environment-attributes)), or an error with id `not_set` if it is unset. There is no default-value overload; use `catch`, e.g. `@env("PORT") catch "8080"`. |
| `@which(name: string)` | `error{not_found}!string` | Path of program `name`, found like the unix `which` command: it is looked up in the `PATH` of the current scope's environment (so a `PATH` set with `[env]` is honored). Fails with `not_found` if it is not found. |
| `@os()` | `string` | The current platform: `"windows"`, `"linux"` or `"macos"`. |
| `@arch()` | `string` | The architecture **family** of the current platform. Its values are those of Zig's `builtin.target.cpu.arch.family()`, for example `"x86"` (both 32-bit and 64-bit x86), `"arm"`, `"aarch64"` or `"riscv"`. The exact set of values is that of the Zig version tasq is built with. |
| `@cwd()` | `string` | The absolute path of the working directory in effect: the task's working directory ([§12.5](#125-working-directory-attribute)), or the directory entered by an enclosing `in` ([§4.11](#411-in-expression)). |
| `@invocation_dir()` | `string` | The directory from which tasq was called. Unlike `@cwd()` it is not affected by the `working_dir` setting or by `in`. |
| `@status_code()` | `number` | Exit status of the most recently executed process. Every process call, statement or expression, updates it, including a process expression evaluated as part of a lazily evaluated static binding ([§3](#3-bindings)). After a process that failed without aborting (`nofail`, or a process expression that produced an error result) it holds that non-zero status. Errors if no process has run yet in the current task. In a parallel construct every branch has its own status ([§13.6](#136-status-code)). |

**File system**

Relative paths given to `@exists`, `@is_file`, `@is_dir`, `@read` and `@glob` are resolved against the working directory in effect ([§12.5](#125-working-directory-attribute), [§4.11](#411-in-expression)), the same one process calls run in. `@basename` and `@join_path` only work on strings and never touch the file system.

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@exists(path: string)` | `bool` | `true` if a file or directory exists at `path`. |
| `@is_file(path: string)` | `bool` | `true` if `path` exists and is a file. `false` if it is missing or is not a file. |
| `@is_dir(path: string)` | `bool` | `true` if `path` exists and is a directory. `false` if it is missing or is not a directory. |
| `@read(path: string)` | `error{read_failed, invalid_utf8}!string` | The content of the file at `path`, exactly as stored (nothing is trimmed). Fails with `read_failed` if the file cannot be read, and with `invalid_utf8` if it is not valid UTF-8. |
| `@glob(pattern: string)` | `[]string` | Lists, recursively, the files and directories that match the glob `pattern`. The result is **not sorted** and its order is unspecified; use `@sort` for a deterministic order. An invalid pattern currently results in an empty list rather than an error ([§15](#15-planned-features)). |
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
| `@parse_number(str: string)` | `error{invalid_format}!number` | Parses `str` as a `number`, or fails with `invalid_format` if it isn't a valid numeric literal. |

**Strings**

| Signature | Returns | Description |
|-----------|---------|-------------|
| `@len(str: string)` | `number` | Number of characters in `str`. |
| `@at(str: string, pos: number)` | `error{out_of_bounds}!string` | The character at index `pos` of `str`, as a `string`. `pos` is rounded up to a whole number first ([§2.1](#21-runtime-types)); fails with `out_of_bounds` if the result is less than `0` or not less than `@len(str)`. |
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
| `@at(list: []T, pos: number)` | `error{out_of_bounds}!T` | The element at index `pos` of `list`. `pos` is rounded up to a whole number first ([§2.1](#21-runtime-types)); fails with `out_of_bounds` if the result is less than `0` or not less than `@len(list)`. |
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
- **Fallible built-ins.** `@env`, `@which`, `@parse_number`, `@at` and `@read` return results ([§2.2](#22-special-types)), with the error ids listed above. Unwrap them with `try` or `catch` ([§4.7](#47-try-and-catch)), or keep the result as a value. The message of an error says exactly what happened, for example which variable or file.
- **Element access.** `@at` reads a single element or character. To take a part of a list or string, use a slice ([§4.9](#49-ranges-and-slices)), which never errors.

**Examples:**

```
task demo {
    // Every file and directory matching the pattern, in a deterministic order
    for(@sort(@glob("src/**/*.zig"), |a, b| a < b)) |path| @print(path)

    // Process output split into lines, each one trimmed
    for(@lines(try $`git status --short`)) |line| @print(@trim(line, " "))

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
        @print(@read("config.toml") catch "")
}
```

> Additional built-in functions will be added in future versions.

---

## 6. Process Calls

A process call runs an external program. It is written as `$`, optional attributes, and an expression that produces the text to run:

```
PROC := '$' [ATTRIBUTES] EXPR
```

```
$`make build`                        // command, interpolated string
$[nofail]`rm -f stale.lock`          // with attributes
$"make build"                        // command, basic string
$r"printf 'a\nb'"                    // command, raw string
$[script]`...multi-line script...`   // script, see 6.4
```

- **Command expression.** `EXPR` is a *primary* expression: a string literal of any form ([§4.2](#42-strings-and-interpolation)), a name, a built-in or lambda call, a parenthesized expression or a slice. Anything larger needs parentheses, e.g. `$("make " + target)`, and so does a result that must be unwrapped first, e.g. `$(try @read("cmd.txt"))`. Its type must be `string`; this is checked during semantic analysis.
- **Literal rules apply.** What the literal does, the process call does: `` $`echo {x}` `` interpolates, `$"echo {x}"` runs the braces as they are, and a raw literal passes backslashes untouched. Any other string value is used as it is.
- **Escapes reach the shell processed.** To give the shell a literal backslash sequence such as `\n`, use a raw literal (`$r"printf 'a\nb'"`) or double the backslash (`` $`printf 'a\\nb'` ``).
- **Result.** As an expression, a process call is a result `error{failed}!string`, unwrapped with `try` or `catch` ([§4.7](#47-try-and-catch)): `` try $`cmd` ``, `` $`cmd` catch "x" ``. With `nofail` it is a plain `string` ([§6.2](#62-failure-handling)).
- **One invocation.** Each process call is **one invocation** of its interpreter ([§7](#7-settings)): `shell` for commands, `script` for scripts ([§6.4](#64-scripts)). It runs in the working directory and environment in effect ([§12.6](#126-environment-and-working-directory-at-a-glance)).
- **No `cd` across calls.** Because every process call is its own invocation, a `cd` inside one does not carry over to later process calls or to built-in functions. To change the working directory, use `in` ([§4.11](#411-in-expression), [§8.9](#89-in-statement)).

### 6.1 Statements and Expressions

A process call is a **statement** when it stands alone as a line of a task body, and an **expression** when it appears where an expression is expected (a binding's right-hand side, an argument, inside an interpolation, a static binding at file root or in a group body, and so on).

| Aspect | Process statement | Process expression |
|--------|-------------------|--------------------|
| Type | none | `error{failed}!string` (`string` with `nofail`) |
| Echo | The command (after interpolation) is echoed first; `noecho` disables. Scripts are not echoed by default ([§6.4](#64-scripts)) | None |
| stdout | Inherited | **Captured**; becomes the value |
| stderr | Inherited | Inherited |
| stdin | Inherited | Empty (reads end-of-file immediately; never waits for input) |
| Non-zero exit | Aborts execution | The expression is an error result with id `failed`; it does not abort by itself |
| `@status_code()` | Updated | Updated |
| Unwrapping | none | `try` / `catch` ([§4.7](#47-try-and-catch)) |

**Captured output.** For a process expression, every newline (`\n` or `\r\n`) at the **end** of the captured output is removed. Nothing else is trimmed: leading whitespace, trailing spaces and tabs, and newlines inside the output are preserved. When the command fails, its output is dropped and only the error remains; to keep the output of a failing command, use `nofail`.

**Static bindings.** A process expression in a static binding runs lazily on first reference, once, and its result (an error result included) is cached, in the environment and working directory of the declaring scope ([§3](#3-bindings)).

### 6.2 Failure Handling

A process fails when it exits with a non-zero status. A process statement then aborts execution, and a process expression produces an error result with id `failed`, whose message says what happened. There is no global switch to change this. Opt out per call:

| Form | On failure |
|------|------------|
| `` $`cmd` `` (statement) | Aborts execution (default) |
| `` $`cmd` `` (expression) | An error result `error{failed}!string`: `try` aborts with its message, `catch` replaces it |
| `` $[nofail]`cmd` `` | Not a failure. A statement simply continues; an expression is a plain `string` holding whatever the command wrote to stdout (possibly nothing). The exit status is available via `@status_code()`. |

A `nofail` expression is not a result, so `try` or `catch` on it is a compile-time error.

```
greeting := try $`echo "Hello"`                   // "Hello"
branch   := try $`git rev-parse --abbrev-ref HEAD`
version  := $`zig --version` catch "unknown"

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

Process attributes are written inline, between the `$` and the command, in a single bracket pair, comma-separated: `` $[nofail, noecho]`cmd` ``. The table in [§12](#12-attributes) lists where each one is valid.

| Attribute | Meta type | Description |
|-----------|-----------|-------------|
| `[nofail]` | flag | A non-zero exit status is not a failure: a statement does not abort, and an expression is a plain `string` instead of a result ([§6.2](#62-failure-handling)). |
| `[noecho]` | `bool` | Do not echo the command before running it. Written without a value it means `true`; `[noecho: false]` forces the echo. The default is `false` for commands and `true` for scripts ([§6.4](#64-scripts)). The command's own output is unaffected. |
| `[script]` | flag | Run the text as a script instead of a command ([§6.4](#64-scripts)). |

- A flag takes no value. `noecho` is the only process attribute that accepts one.
- `noecho` has no meaning on a process expression, which is never echoed; using it there is a compile-time error.
- Applying the same attribute twice to one process call is a compile-time error.

### 6.4 Scripts

A **script** is a multi-line program that is run from a file instead of as a one-line command. Mark a process call with `[script]` to make it one:

```
task test(num: number) $[script]`
    echo "Adding {num} to a number read from stdin"
    read second_num
    echo "$(({num} + $second_num))"
`
```

- **How it runs.** tasq writes the text to a temporary file and runs the interpreter from the `script` setting ([§7](#7-settings)) with the path of that file appended as the last argument. A command, by contrast, is passed as the last argument of `shell`, as with `-c`.
- **Interpreter defaults.** On Linux the default is `["/bin/sh", "-eu"]`, so an unset variable or a failing command stops the script. Set `script` to use another interpreter, e.g. `set script = ["bash", "-euo", "pipefail"]`.
- **Stdin.** The script text is not sent through stdin, so stdin stays available to the script exactly as for any other process call ([§6.1](#61-statements-and-expressions)).
- **Echo.** Scripts are not echoed. `[noecho: false]` echoes the script text like a command. This default may change ([§15](#15-planned-features)).
- **Everything else is as for any process call.** A script may be a statement or an expression, accepts `nofail`, and as an expression is a result like any process call (`try`, `catch`), and updates `@status_code()`.
- **Which literal.** The text is any string expression. A multi-line backtick string ([§4.2](#multi-line-strings)) is the usual choice; use a raw backtick string for a script that is full of braces: ``$[script]r`...` ``.

---

## 7. Settings

Settings configure global interpreter behavior. They are declared at **file root**, and **each setting may be declared only once** per platform ([§12.1](#121-platform-attributes)); a declaration without a platform attribute counts for all platforms.

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
set shell = ["cmd", "/C"]

[linux]
set shell = ["bash", "-c"]

[macos]
set shell = ["zsh", "-c"]
```

**Values.** Setting values are meta values ([§2.3](#23-meta-types)), so a string may be written quoted or as a bare identifier, and each setting's constraints are enforced at compile time:

```
set task_label = full       // same as: set task_label = "full"
set task_label = "idk"      // compile-time error: "idk" is not one of none, name, full
```

**Available settings:**

| Setting | Meta type | Description |
|---------|-----------|-------------|
| `shell` | `[]string(min_items = 1)` | Interpreter for command process calls. The command is appended as the last argument, e.g. `["/bin/sh", "-c"]`. |
| `script` | `[]string(min_items = 1)` | Interpreter for script process calls ([§6.4](#64-scripts)). The path of the script file is appended as the last argument, e.g. `["/bin/sh", "-eu"]`. |
| `dotenv` | `bool \| string` | Whether to read a `.env` file into the environment. `set dotenv` enables the default `.env` file in `working_dir`; `set dotenv = "path/to/file"` enables it using that file instead. Default: `false`. See [§12.4](#124-environment-attributes) for how loaded values interact with `[env]` and the OS environment. |
| `working_dir` | `string` | The root working directory. Defaults to the directory `tasq` was invoked from. It is the base of every task's working directory ([§12.5](#125-working-directory-attribute)), the working directory of static bindings ([§3](#3-bindings)), and the base for the default `.env` path. |
| `jobs` | `number(int, min = 1)` | The global budget of parallel execution ([§13.1](#131-model-and-limits)): the maximum number of threads that execute tasq code at the same time, the main thread included. tasq never creates more threads than this value; `set jobs = 1` runs everything sequentially. Default: the number of CPUs. |
| `task_label` | `string([none, name, full])` | Whether tasq announces a task when it starts running. See below. Default: `none`. |

**Interpreter defaults:**

| Setting | Windows | Linux and macOS |
|---------|---------|-----------------|
| `shell` | `["cmd", "/C"]` | `["/bin/sh", "-c"]` |
| `script` | `["cmd", "/C"]` | `["/bin/sh", "-eu"]` |

**Task labels.** `task_label` selects what is printed before a task runs:

| Value | Printed before the task runs |
|-------|------------------------------|
| `none` | Nothing. |
| `name` | The name of the task. |
| `full` | The name of the task and its arguments. |

The label is printed for every task that runs: the one named on the command line, its dependencies and the tasks it calls. A dependency that is skipped as already run ([§8.8](#88-task-dependencies)) does not run and prints nothing. The exact text of the label is not specified yet.

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

An argument is **named** when it has at least one CLI name, a short name (`-x`), a long name (`--xyz`) or both, and **positional** when it has none. CLI names are never assigned automatically: they come only from the `[long]` and `[short]` attributes ([§12.3](#123-argument-attributes), [§11.4](#114-cli-names)).

Arguments in a task or group declaration **must appear in this order**; violating it is a compile-time error.

| Phase | Kind | Characteristics |
|-------|------|-----------------|
| 1st | **Positional required** | No CLI name; no default; only `string` and `number` |
| 2nd | **Positional optional** | No CLI name; has a default (`= <value>`); only `string` and `number` |
| 3rd | **Named required** | Has a CLI name; no default |
| 4th | **Named optional** | Has a CLI name; has a default (`= <value>`) |

**Rules:**

- Whether an argument is positional or named depends only on its names. Neither its type nor its default value changes it.
- Arguments of type `flag`, `string_list` or `number_list` are inherently non-positional, and so are all group arguments ([§10.1](#101-named-groups)). Each of them must be given `[long]` and/or `[short]`; without a name it is a compile-time error.
- A `flag` has the implicit default `false`, so a caller may omit it ([§9](#9-task-calls)), but it is placed in the named-required phase.

```
task deploy(
    // 1. Positional required
    target: string,

    // 2. Positional optional
    retries: number = 3,

    // 3. Named required (a flag must be named explicitly)
    [long, short]
    verbose: flag,

    // 4. Named optional
    [long]
    region: string = "eu",
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
| Parallel block | `parallel[(n)] { ... }` ([§13.3](#133-parallel-block)) |
| Task call | `name(...)` / `::name(...)` / `group::name(...)` ([§9](#9-task-calls)) |
| Expression statement | Any other expression, e.g. `@print(msg)` |

**Expression statements.** A line that matches none of the other forms is parsed as an expression whose value is discarded. This is what lets `@print(...)` stand alone on a line: its type is `void`, so discarding it is harmless.

**Discarding values.** An expression statement whose value is not `void` (or `noreturn`) is a compile-time error (`discarded value`), because the value would be silently lost. This includes a result: unwrap it with `try` or `catch`. To evaluate an expression and deliberately ignore its result, bind it to `_`:

```
_ := double(2)        // evaluated, result discarded
```

`_` is never defined as a name, so it cannot be read, and may be used any number of times in one scope.

**Statement blocks.** Wherever statements are expected (a task body, the branches of `if`, the body of `for`, the body of `in`, the body of a `switch` branch), the grammar accepts a *statement block*:

```
STMT_BLOCK := '{' STATEMENTS '}' | STATEMENT
```

A block with exactly one statement may omit its braces. This is one general rule, not a special form of any construct; a brace-less task such as `task build $`cc main.c`` is simply a consequence of it. The parallel block is the exception: it always needs its braces ([§13.3](#133-parallel-block)). A statement block is not a block expression ([§4.12](#412-block-expression)): where an expression is expected, `{ ... }` holds bindings and a result expression instead.

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
- Patterns are literals only and must be unique (compile-time errors), as in the expression form ([§4.4](#44-switch-expression)). An error subject, available in a `catch` handler, takes its ids as patterns, and an `else` after covering every id is a warning ([§4.4](#switching-on-an-error)).
- `else` is **optional**. If nothing matches and there is no `else`, execution continues after the `switch`.

### 8.7 For Statement

`for` as a **statement** iterates over one or more lists or ranges in lock-step, running a block for each step. Unlike the `for` expression ([§4.5](#45-for-expression)), it produces no value.

```
for(<subjects>) [parallel[(<n>)]] |<captures>| <stmt_block>
```

- `<subjects>`, `<captures>` and the iteration rules (shared window, shortest-subject bound, clamping, unbounded ranges) are exactly those of the `for` expression ([§4.5](#45-for-expression)), defined in [§4.9](#49-ranges-and-slices).
- `<stmt_block>` is a `{ }` block or a single statement ([§8.4](#84-task-body)).
- `break` and `continue` ([§4.6](#46-break-and-continue)) may be used inside, including from a nested `if`, `switch` or `in`.
- `parallel`, when written, runs the iterations concurrently ([§13.2](#132-parallel-for)). `continue` then ends the current iteration, and `break` is not allowed.

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
- Dependencies run before the body, one after another, **in the order listed**. They never run in parallel (running dependencies in parallel is a planned feature, [§15](#15-planned-features)).
- A dependency's arguments are ordinary expressions. They may use the task's **own arguments** (e.g. `[compile(target)]`), the group's shared arguments, static bindings and built-ins. The task body has not run yet, so its task-local bindings do not exist and cannot be used.
- The task's `[env]` attributes ([§12.4](#124-environment-attributes)) **apply to its dependencies**, as if the task had called them itself.
- Each dependency runs in its own working directory ([§12.5](#125-working-directory-attribute)), like any task.
- The list sits after the signature, so it is never confused with an attribute list ([§12](#12-attributes)), which precedes the `task` keyword.
- A task with dependencies may also have a brace-less body ([§8.4](#84-task-body)).
- Dependencies only **order** tasks. tasq never skips a task because its outputs are up to date.

#### Deduplication

A dependency that has already run is not run again. This is what makes a shared dependency (a `build` that both `test` and `lint` need) run once.

**Call trees.** Every *call* starts a new **call tree**: the task named on the command line ([§11](#11-command-line-interface)) and every task call statement in a body ([§9](#9-task-calls)) is the root of its own tree. A tree consists of the called task, its dependencies, their dependencies, and so on. Deduplication happens **inside one tree** and never across trees.

- **Identity.** A run is identified by the task together with its **resolved arguments**: defaults are filled in first, and for a task in a group the group's shared arguments are included. Arguments are compared by value, and lists element by element, in order. So `build()` and `build(release: false)` are the same run when `release` defaults to `false`, while `deploy("staging")` and `deploy("prod")` are different runs. The working directory is not part of the identity, because it depends only on the task itself ([§12.5](#125-working-directory-attribute)).
- **Skipping.** When a dependency's identity matches a run that already **finished** in the same tree, the dependency is skipped, silently.
- **The root is never skipped.** The task that starts a tree always runs.
- **Arguments are evaluated first.** A dependency's identity depends on its arguments, so they are evaluated even if the dependency then turns out to be skipped. Keep dependency arguments free of side effects.

**Evaluation order.** A dependency's arguments are evaluated right before that dependency starts, left to right through the list. A later dependency's arguments can therefore observe the effects of the earlier dependencies:

```
[generate(), show(@read("version.txt") catch "none")]   // version.txt is read after generate() has run
```

**Failure.** The first failure aborts the whole run: the remaining dependencies and the body do not run, and tasq exits with a non-zero status.

**Cycles.** A task cannot depend on itself, directly or through other tasks. Each of the following is a compile-time error, and `tasq --check` reports the cycle:

```
task a [a()] { ... }

task b [c()] { ... }
task c [b()] { ... }
```

Only dependency lists are checked. A cycle through task call statements ([§9](#9-task-calls)), such as two tasks that call each other from their bodies, is **not detected** yet ([§15](#15-planned-features)); running one never terminates normally.

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

A task call *statement* is not a dependency: it starts a new tree and always runs ([§9](#9-task-calls)).

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
host := try $`uname -a`

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

`in` as a **statement** changes the working directory for a block of statements. The semantics are shared with the expression form and described in [§4.11](#411-in-expression): the path is resolved against the working directory in effect, the previous directory is restored however the block is left, the environment is not changed, and a called task does not inherit the directory.

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

**Inherited context.** A called task inherits the effective environment in effect at the call, which reverts when the call returns. The working directory is **not** inherited: a task always runs in its own working directory, no matter who calls it or from inside which `in` block ([§12.6](#126-environment-and-working-directory-at-a-glance)).

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

**Cycles.** A task must not call itself, directly or through other tasks. Cycles through call statements are not detected ([§8.8](#88-task-dependencies)).

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
    [long]
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
- Group arguments are always **named**: each one needs `[long]` and/or `[short]` ([§11.4](#114-cli-names)), otherwise it is a compile-time error.
- Group arguments are shared by every task in the group.
- A group may carry `[cwd]`, which applies to every task in it ([§12.5](#125-working-directory-attribute)).
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
    [long]
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
| `-h`, `--help` | Show the help message ([§11.6](#116-choosing-the-file-and-option-placement) for placement). |

### 11.2 Checking Without Running (`--check`)

```
tasq --check
```

`--check` runs the compiler over the `tasq` file (parsing, name resolution, type checking and every other check the spec calls a *compile-time error*, constraint violations of settings and attributes included) and prints the resulting **diagnostics**. It then stops: **no task is run**.

**What it does not do:**

- It executes nothing. No task body runs, no process call is spawned (statement or expression), and no binding is evaluated.
- Because nothing runs, it cannot detect **runtime** failures: a `try` that meets an error (a command exiting non-zero, a missing environment variable, an unparsable `@parse_number` input, an `@at` position out of bounds, an unreadable `@read` file), an `@error(...)` being reached, and so on.
- Lambdas are checked in two stages ([§4.8](#48-lambdas)): at their definition, with parameters of unknown type, and at each use, with the concrete types. Errors that depend on a parameter's type can therefore only be found for lambdas that are used.

**Exit status.** `tasq --check` exits with a non-zero status when at least one error diagnostic is reported, so it can be used in scripts and CI. Warnings (for example an unreachable `else`, [§4.4](#switching-on-an-error)) are printed too but do not change the exit status.

### 11.3 Task Arguments

**Positional arguments** are passed by position, in declaration order. Only `string` and `number` may be positional. Trailing optional positional arguments may be left out and take their defaults; an optional argument cannot be skipped in order to give a later one.

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

### 11.4 CLI Names

An argument has CLI names only when they are requested explicitly with `[long]` and `[short]` ([§12.3](#123-argument-attributes)). Nothing is derived automatically, and an argument without a name is positional ([§8.3](#83-argument-ordering)).

| Attribute | CLI name |
|-----------|----------|
| `[long]` | `--` and the identifier |
| `[long: "tag"]` | `--tag` |
| `[short]` | `-` and the first letter of the identifier |
| `[short: 't']` | `-t` |
| `[long: null]`, `[short: null]` | no such name (the same as leaving the attribute out) |

A `flag`, a list or a group argument ([§8.3](#83-argument-ordering)) with no name is a compile-time error.

```
task example(
    [long: "tag", short: 't']  // --tag, -t
    tags: string_list,

    [long]                     // --verbose
    verbose: flag,

    [short: 'x']               // -x only
    extra: flag,

    [long, short]              // --retries, -r
    retries: number = 3,
) { ... }
```

### 11.5 Listing Tasks and Showing Usage

**`tasq --list`** displays the tasks of the file, grouped by group. Each task is shown with the names of its positional arguments and its `[desc]` description ([§12.2](#122-documentation-attributes)). `[private]` tasks and groups are omitted.

**`tasq --usage <task_name>`** displays the usage of one task: its signature, that is its arguments with their CLI names ([§11.3](#113-task-arguments), [§11.4](#114-cli-names)) and default values, together with the `[desc]` descriptions of the task and of its arguments.

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

- Attribute values are **meta values**: compile-time literals, checked against the attribute's meta type and constraints ([§2.3](#23-meta-types)). A string value may be written quoted or as a bare identifier: `[desc: hello]` and `[desc: "hello"]` are the same.
- An attribute written without a value is a **flag**, except where noted (`noecho` is a `bool` and may also be written with a value).
- **Process-call attributes** are the one exception to the placement rule: they are written inline between the `$` and the command ([§6.3](#63-process-attributes)).
- **Uniqueness** is a property of each attribute. A *unique* attribute may be applied at most once per element (twice is a compile-time error); a *repeatable* attribute may be applied multiple times.

**Where each attribute is valid** (this table is the single reference for validity and uniqueness; the subsections below describe meaning):

| Attribute | `task` | `group` | argument | `set` | process stmt | process expr | Unique |
|-----------|:------:|:-------:|:--------:|:-----:|:------------:|:------------:|:------:|
| `[windows]` `[linux]` `[macos]` | ✓ | ✓ | | ✓ | | | Yes |
| `[desc]` | ✓ | ✓ | ✓ | | | | Yes |
| `[private]` | ✓ | ✓ | | | | | Yes |
| `[cwd]` | ✓ | ✓ | | | | | Yes |
| `[long]` `[short]` | | | ✓ | | | | Yes |
| `[int]` `[min]` `[max]` `[pattern]` `[min_items]` `[max_items]` | | | ✓ | | | | Yes |
| `[env]` | ✓ | | | | | | No (repeatable) |
| `[nofail]` | | | | | ✓ | ✓ | Yes |
| `[noecho]` | | | | | ✓ | | Yes |
| `[script]` | | | | | ✓ | ✓ | Yes |

### 12.1 Platform Attributes

Restrict the element to one operating system. Elements with no platform attribute apply to **all** platforms.

| Attribute | Platform |
|-----------|----------|
| `[windows]` | Windows |
| `[linux]` | Linux |
| `[macos]` | macOS |

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

| Attribute | Meta type | Description |
|-----------|-----------|-------------|
| `[desc: "text"]` | `string` | Human-readable description shown by `tasq --list` and `tasq --usage` ([§11.5](#115-listing-tasks-and-showing-usage)). |
| `[private]` | flag | Hides the task or group from `tasq --list` output. A private task can still be called normally, by name from another task or directly from the command line; it is only omitted from generated documentation. |

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

**Naming.** `long` and `short` each come in three forms; each of the two attributes is unique. Names are never assigned automatically ([§11.4](#114-cli-names)): an argument that has neither attribute is positional.

| Attribute | Meta type | Description |
|-----------|-----------|-------------|
| `[long]` | flag | Use the identifier as the long name (`--identifier`) |
| `[long: "name"]` | `string` | Use a custom long name |
| `[long: null]` | `null` | Remove the long name |
| `[short]` | flag | Use the identifier's first letter as the short name (`-i`) |
| `[short: 'c']` | `char` | Use a custom short name |
| `[short: null]` | `null` | Remove the short name |

**Validation.**

| Attribute | Meta type | Applies to | Description |
|-----------|-----------|------------|-------------|
| `[int]` | flag | `number`, `number_list` | Integers only; reject floating-point input |
| `[min: n]` | `number` | `number`, `number_list` | Minimum allowed value (inclusive) |
| `[max: n]` | `number` | `number`, `number_list` | Maximum allowed value (inclusive) |
| `[pattern: "regex"]` | `string` | `string`, `string_list` | Validate each value against a regular expression |
| `[min_items: n]` | `number(int, min = 0)` | `string_list`, `number_list` | Minimum number of list items |
| `[max_items: n]` | `number(int, min = 1)` | `string_list`, `number_list` | Maximum number of list items |

- `min` greater than `max`, or `min_items` greater than `max_items`, on one argument is a compile-time error.

> Additional validation attributes will be added in future versions.

```
task create_user(
    // 1. Positional required
    username: string,

    // 2. Positional optional, with validation
    [int, min: 13, max: 150, desc: "Age of the user"]
    age: number = 18,

    // 3. Named required: custom names and item limits
    [long: "tag", short: 't', min_items: 1, max_items: 10]
    tags: string_list,

    // Flag: names are requested explicitly (--verbose, -v)
    [long, short]
    verbose: flag,

    // 4. Named optional, with pattern validation
    [long, pattern: "^[\\w._%+\\-]+@[\\w.\\-]+\\.[a-z]{2,}$"]
    email: string = "",
) {
    $`echo "Creating {username}, age {age}"`
}
```

### 12.4 Environment Attributes

| Attribute | Meta type | Description |
|-----------|-----------|-------------|
| `[env: (string,string)]` | `(string,string)` | Sets an environment variable for the task: the first tuple element is the name, the second the value. Write it once per variable to set several. |

**Scope:**

- An `[env]` variable is visible to `@env(...)`, `@which(...)` (which searches the `PATH` of that environment) and spawned processes (process calls) anywhere within the declaring task, including task-local bindings and process expressions. All three always see the same environment.
- If the task calls another task, including a dependency ([§8.8](#88-task-dependencies)), the variable is **inherited** by the callee and reverts when control returns to the caller. `[env]` is scoped dynamically to the call subtree rooted at the declaring task, not a permanent run-wide mutation.
- If a called task declares its own `[env]` for the same name, that value takes precedence for the duration of that call, and the earlier one resumes on return (ordinary nested shadowing).
- **Static bindings** ([§3](#3-bindings)) never see the `[env]` of the task that triggers them. They are evaluated in the environment of the scope they are declared in: the `.env` file (if enabled) and the OS environment.
- **Task-local bindings** see the task's effective environment: its own `[env]` plus whatever it inherited.
- `in` ([§4.11](#411-in-expression), [§8.9](#89-in-statement)) does not change the environment.
- Every branch of a parallel construct runs in the environment in effect where the construct is written, and a task called from a branch inherits it as from any other place ([§13.1](#131-model-and-limits)).

**Precedence.** When a variable could come from several sources, the most specific wins:

1. `[env: (...)]` attributes in effect at the current point in the call chain
2. Values from a `.env` file, if the `dotenv` setting ([§7](#7-settings)) is enabled
3. The pre-existing OS environment

Static bindings start at step 2, since no `[env]` is in effect for them.

```
[env: ("NODE_ENV", "production")]
[env: ("LOG_LEVEL", "warn")]
task deploy {
    $`echo "Running in {@env("NODE_ENV") catch "unknown"}"`
    build() // NODE_ENV and LOG_LEVEL are inherited here too
}
```

**Static vs. task-local bindings:**

```
// Static: always sees the root environment (a raw string keeps the shell's braces as they are)
layer := try $r`echo "${LAYER:-unset}"`

[env: ("LAYER", "task")]
task show {
    @print(layer)                              // "unset" (if LAYER isn't set in the OS environment)
    local := try $r`echo "${LAYER:-unset}"`
    @print(local)                              // "task"
}
```

### 12.5 Working Directory Attribute

| Attribute | Meta type | Description |
|-----------|-----------|-------------|
| `[cwd: "path"]` | `string` | Sets the directory a task runs in. On a group it applies to every task of the group, named or anonymous. |

**Working directory of a task.** The directory a task starts in is always:

```
working_dir (setting)  +  group cwd  +  task cwd
```

Each part is optional. `working_dir` ([§7](#7-settings)) defaults to the directory tasq was invoked from. A group's `cwd` is relative to it, and a task's `cwd` is relative to the result so far. A task with no `cwd`, in a group with no `cwd`, runs in `working_dir`.

- **Independent of the caller.** The result depends only on the task's own definition. It is the same whether the task is run from the command line, listed as a dependency or called from a body, and a call made from inside an `in` block does not change it ([§4.11](#411-in-expression)). This is why the working directory is not part of a dependency's identity ([§8.8](#88-task-dependencies)).
- **What it affects.** Every process call and the file-system built-ins (`@glob`, `@exists`, `@read`, `@is_file`, `@is_dir`, [§5](#5-built-in-functions)) in the task body start in this directory, and so does `@cwd()`. `in` replaces it for a block, and a relative `in` path is resolved against it ([§4.11](#411-in-expression)).
- **What it does not affect.** Static bindings are evaluated in the root working directory, never in the `cwd` of whatever task triggers them ([§3](#3-bindings)). `@invocation_dir()` is unchanged.
- The `cwd` value is a meta `string` ([§2.3](#23-meta-types)), so it cannot be computed.
- If the resulting directory does not exist when the task runs, the run aborts with an error.

```
[cwd: "services"]
group {
    [cwd: "api"]
    task test {
        $`go test ./...`           // runs in <working_dir>/services/api
    }

    task lint {
        $`golangci-lint run`       // runs in <working_dir>/services
    }
}

task whereami {
    @print(@cwd())
}

[cwd: "docs"]
task docs {
    @print(@cwd())                 // <working_dir>/docs
    in("build") {
        @print(@cwd())             // <working_dir>/docs/build
        whereami()                 // prints <working_dir>: the called task uses its own directory
    }
}
```

### 12.6 Environment and Working Directory at a Glance

This table summarizes the rules of [§3](#3-bindings), [§4.8](#48-lambdas), [§4.11](#411-in-expression), [§8.8](#88-task-dependencies), [§9](#9-task-calls), [§12.4](#124-environment-attributes), [§12.5](#125-working-directory-attribute) and [§13](#13-parallel-execution) in one place. Where it differs from those sections, they are authoritative.

| Where code runs | Environment | Working directory |
|-----------------|-------------|-------------------|
| Task body, including task-local bindings | The task's effective environment: its own `[env]` plus what it inherited | The task's own directory ([§12.5](#125-working-directory-attribute)), or the directory entered by an enclosing `in` |
| Static binding (file root, group body) | `.env` file (if enabled) and OS environment; never a task's `[env]` | The root working directory (`working_dir`); never a task's `cwd` or an `in` |
| Task called by a call statement | Inherits the caller's effective environment; reverts on return | Always its own directory |
| Dependency | Inherits the declaring task's effective environment, including its `[env]` | Always its own directory |
| Block inside `in` | Unchanged | The entered directory; restored when the block is left |
| Lambda body | The environment in effect where the lambda is **called** | The directory in effect where the lambda is **called** |
| Branch of a parallel construct | Its own copy of the environment in effect where the construct is written | Its own copy of the directory in effect there (an enclosing `in` included); an `in` inside the branch changes only that branch |

`@invocation_dir()` is never affected by any of the above.

---

## 13. Parallel Execution

By default tasq runs everything sequentially. Writing the keyword **`parallel`** makes a construct run its parts concurrently. Three constructs have a parallel form:

| Construct | Syntax | Concurrent parts (*branches*) | See |
|-----------|--------|-------------------------------|-----|
| `for` expression and statement | `for(<subjects>) parallel[(<n>)] \|<captures>\| ...` | the iterations | [§13.2](#132-parallel-for) |
| Parallel block (statement) | `parallel[(<n>)] { <statements> }` | the statements | [§13.3](#133-parallel-block) |
| Parallel block expression | `parallel[(<n>)] { <bindings> <result expression> }` | the bindings | [§13.4](#134-parallel-block-expression) |

The optional `(<n>)` limits how many branches run at the same time. Task dependencies are never parallel ([§8.8](#88-task-dependencies)).

```
task compress {
    // at most 4 files at a time
    for(files) parallel(4) |f| $`gzip {f}`

    // three different jobs at once
    parallel {
        lint()
        test()
        $`cargo doc`
    }
    deploy()          // runs after the block has finished
}
```

### 13.1 Model and Limits

**Branches.** The unit of concurrency is a *branch*: one iteration of a parallel `for`, one statement of a parallel block, one binding of a parallel block expression. Branches are numbered in order: by iteration index, by statement position and by binding position.

**Join.** A parallel construct finishes only when all of its branches have finished. Whatever follows it runs afterwards. Nothing is ever left running in the background.

**Scopes.** Every branch runs in a scope of its own, created when the branch starts. The scope starts with a copy of the environment and the working directory in effect where the construct is written ([§12.6](#126-environment-and-working-directory-at-a-glance)). What a branch changes (an `in` block, a called task with `[env]`) is visible only to that branch. Because bindings are immutable, branches cannot change each other's values; the few things they do share are listed in [§13.7](#137-interaction-with-other-features).

**Order of start.** Branches are started in order, the lowest-numbered branch that has not started yet first. They may finish in any order.

**The limit `(n)`.** `n` is an expression of type `number`, evaluated once before the first branch starts. It is a whole-number context ([§2.1](#21-runtime-types)): it is rounded up, and a result below `1` counts as `1`. It means *at most `n` branches of this construct run at the same time*. Without it, the construct is limited only by the global budget.

**The global budget.** The `jobs` setting ([§7](#7-settings)) is the global budget: the number of threads that may execute tasq code at the same time, **the main thread included**. tasq never creates more threads than this budget allows, so at most `jobs - 1` helper threads exist at any moment. `jobs` defaults to the number of CPUs.

- The thread that reaches a parallel construct takes part in running its branches itself, and borrows helper threads from the budget only if any are left.
- Nested parallel constructs share the one budget. An inner construct can therefore run fewer branches concurrently than its limit says, or none: its branches then run one after another on the calling thread. This never waits for a free thread and cannot deadlock.
- `(n)` never raises the budget; it only lowers what one construct may use.
- `set jobs = 1` turns concurrency off: every parallel construct runs its branches one after another, in order.
- A construct whose branches mostly wait for external processes may benefit from a `jobs` value above the CPU count.

```
set jobs = 8

task example {
    // 3 files at a time, inside a global budget of 8 threads
    for(files) parallel(3) |f| $`gzip {f}`
}
```

### 13.2 Parallel For

```
for(<subjects>) parallel[(<n>)] |<captures>| <expr>          // expression
for(<subjects>) parallel[(<n>)] |<captures>| <stmt_block>    // statement
```

The subjects, the captures and the window of indices work exactly as in a sequential `for` ([§4.9](#49-ranges-and-slices)): list subjects, ranges, lock-step, clamping. The only difference is that the iterations run concurrently. Each iteration gets its own scope with its own captures.

| | Expression | Statement |
|---|------------|-----------|
| Result | A list, **in input order**, whatever the order in which the iterations finish | None |
| `continue` | The element is dropped from the list | The iteration ends |
| `break` | Compile-time error | Compile-time error |

`break` is not allowed, because there is no stable meaning of "stop here" while other iterations are already running.

```
// Results keep input order, even if the first iteration finishes last
sizes := for(["big.iso", "a.txt", "b.txt"]) parallel |f| try $`stat -c %s {f}`

// `continue` filters in the expression form
up := for(hosts) parallel(8) |h| if ($[nofail]`ping -c1 {h}` == "") continue else h

// Statement form: index capture, `continue` ends one iteration
for(files, 0..) parallel |f, i| {
    if (@is_dir(f)) continue
    $`process {f} --id {i}`
}
```

Parallel loops can be nested; the inner loop shares the global budget ([§13.1](#131-model-and-limits)):

```
grid := for(["a", "b"]) parallel |x| for([1, 2]) parallel |y| try $`echo {x}{y}`   // [[a1, a2], [b1, b2]]
```

### 13.3 Parallel Block

```
parallel[(<n>)] {
    <statement>
    <statement>
    ...
}
```

A parallel block is a statement. **Every statement of the block is one branch**, and all of them run concurrently. A statement that contains blocks of its own (`if`, `switch`, `for`, `in`) is still a single branch as a whole. Any statement is allowed: process statements, task calls, `if`, `switch`, `for` (also a parallel one), `in`, expression statements such as `@print(...)`, and bindings.

- **Braces are required.** A single statement has nothing to run alongside, so the brace-less form of [§8.4](#84-task-body) does not apply to the parallel block.
- **Every statement runs in a scope of its own.** A binding is allowed, mainly so that a value can be discarded legally with `_ := ...` ([§8.4](#84-task-body)). The names it introduces are visible only inside that statement: other statements of the block and the code after the block can never read them. To use the values, write a parallel block expression ([§13.4](#134-parallel-block-expression)).
- **`break` and `continue`** cannot refer to a `for` that encloses the block ([§4.6](#46-break-and-continue)): that is a compile-time error. Inside a `for` that is itself in a branch they work as usual.
- The block finishes when all of its statements have finished.

```
task build_all {
    parallel(2) {
        in("frontend") $`npm run build`     // `in` affects only this branch
        in("backend")  $`cargo build`
        _ := try $`git describe --tags`     // evaluated for its side effects, result discarded
        if (@os() != "windows") docs()
        for(images) parallel |img| $`optimize {img}`
    }
    @print("everything built")
}
```

### 13.4 Parallel Block Expression

```
parallel[(<n>)] {
    <binding>
    <binding>
    ...
    <result expression>
}
```

A parallel block expression is the parallel form of a block expression ([§4.12](#412-block-expression)): the bindings run concurrently, and a result expression combines their values.

- **Every binding is one branch**, plain, destructuring or `_ :=`. It runs in a scope of its own ([§13.1](#131-model-and-limits)) that sees the names visible where the construct is written, but **not its siblings**: referencing a name bound by another branch is a compile-time error.
- **The result expression** is evaluated once, when **all** branches have finished, on the thread that reached the construct and in the scope where the construct is written. Only it sees the names bound by the block, all of them. They are visible nowhere else. The value and type of the whole expression are those of the result expression.
- **Braces are required**, as for the parallel block.
- **`break` and `continue`** cannot refer to a `for` that encloses the construct from inside a binding (compile-time error). The result expression runs after the join, so there they work as in a sequential block ([§4.12](#412-block-expression)).
- If a branch fails, the result expression is not evaluated ([§13.5](#135-failure)).

```
// Three independent lookups cost as much as the slowest one
info := parallel {
    sha    := try $`git rev-parse --short HEAD`
    branch := try $`git branch --show-current`
    day    := try $`date +%F`
    `{sha} {branch} {day}`
}

// Gather concurrently, then continue with ordinary statements
staging, prod := parallel {
    s := try $`curl -fsS https://staging.example.com/version`
    p := try $`curl -fsS https://example.com/version`
    (s, p)
}

// Siblings are invisible to each other
bad := parallel {
    a := try $`make a`
    b := `{a}`      // compile-time error: `a` belongs to another branch
    b
}
```

### 13.5 Failure

A branch fails when it aborts the run in the usual way: a process statement that exits non-zero without `nofail`, a `try` that meets an error, `@error(...)`, an error raised by a task it called, and so on.

- Every failing branch reports its error as it would in a sequential run.
- After the first failure **no further branch is started**. Branches that are already running are **not interrupted**; they finish normally. Branches that never started are skipped silently.
- When the running branches have finished, the construct aborts the run, and tasq exits with a non-zero status as for any other failure. Nothing after the construct runs, and a failing parallel block expression does not evaluate its result expression.

### 13.6 Status Code

`@status_code()` ([§5](#5-built-in-functions)) is kept per scope, so every branch has its own.

- Inside a branch it holds the status of the last process that branch ran. Before the branch has run one, it holds the value in effect where the construct is written, as in any nested block.
- A branch never changes the status that other branches see.
- When the construct has finished, the status is that of the **highest-numbered branch that ran a process**. This is the value a sequential run of the same construct would leave, whatever the order in which the branches finished. If no branch ran a process, the status is unchanged. The result expression of a parallel block expression sees this value.

### 13.7 Interaction with Other Features

**Static bindings.** A static binding that several branches reference for the first time at the same moment is still evaluated **once** ([§3](#3-bindings)): one branch evaluates it while the others wait for the result. If its evaluation aborts, the run aborts ([§13.5](#135-failure)).

**Task calls.** A task call statement in a branch runs the task as anywhere else: the task inherits the environment of the branch, runs in its own working directory, and starts its own call tree ([§8.8](#88-task-dependencies), [§9](#9-task-calls)). Call trees of different branches are independent, so deduplication never works across branches: two branches that call the same task run it twice, possibly at the same time. The dependencies of a task are never parallel, also when the task is called from a parallel branch.

**Environment and working directory.** Private to each branch, see [§13.1](#131-model-and-limits) and [§12.6](#126-environment-and-working-directory-at-a-glance).

**Output and input.** tasq does not order or group the output of concurrent branches. Echoed commands, task labels ([§7](#7-settings)), `@print` output and the output of the processes themselves appear as they are produced and may interleave. Process expressions capture their output ([§6.1](#61-statements-and-expressions)), so they never interleave; use them, or `noecho`, where readable output matters. Process statements inherit stdin as usual, so branches that read from the terminal compete for the input: avoid interactive commands in parallel branches.

### 13.8 Compile-Time Errors

| Mistake | Example |
|---------|---------|
| `break` in a parallel `for` (expression or statement) | `for(xs) parallel \|x\| if (x < 0) break else x` |
| `break` or `continue` that refers to a `for` outside a parallel block, or outside a branch of a parallel block expression | `for(xs) \|x\| { parallel { break } }` |
| A sibling's binding used in a parallel block expression | `parallel { a := 1  b := a  b }` |
| A limit that is not a `number` | `parallel("4")` |
| A parallel block without braces | `parallel $`make`` |
| A `jobs` setting that is not a whole number of at least `1` | `set jobs = 0`, `set jobs = 2.5` |

---

## 14. Quick Reference

### Literals

| Literal | Type | Interpolation | Notes |
|---------|------|:-------------:|-------|
| `"text"` | `string` | No | Basic string, single line, escapes |
| `r"text"` | `string` | No | Raw string, single line, no escapes |
| `` `text {expr}` `` | `string` | Yes (`{ }`) | Interpolated string, single or multi-line, escapes ([§4.2](#42-strings-and-interpolation)) |
| ``r`text` `` | `string` | No | Raw backtick string, single or multi-line, no escapes |
| `'c'` | `char` | No | Single character |
| `("a", 1)` | tuple | No | Two or more elements of any value type, lambdas included ([§4.10](#410-tuples-and-destructuring)) |
| `\|a, b\| expr` | lambda | No | Single-expression function; types inferred per use ([§4.8](#48-lambdas)) |
| `` $[attrs] <string expr> `` | process call | By its literal | Statement, or expression of type `error{failed}!string` (`string` with `nofail`); e.g. `` $`command {expr}` `` ([§6](#6-process-calls)) |

Escape sequences (valid in every non-raw literal): `\n` `\t` `\r` `\\` `\"` `\'` ``\` `` `\0` `\xNN` `\u{NNNN...}` `\{` `\}`

### Expression Forms

| Form | Meaning | See |
|------|---------|-----|
| `a and b`, `a or b`, `not a` | Boolean operators; there is no `!` operator. Precedence: comparison, then `not`, then `and`, then `or` | [§4.1](#41-operators) |
| `if (c) a else b` | Conditional expression | [§4.3](#43-if-expression) |
| `switch(x) { p => a, else => b }` | Multi-way expression; on an error value the patterns are its ids | [§4.4](#44-switch-expression) |
| `for(list) \|x\| expr` | Builds a list: map, filter (`continue`), take-while (`break`), validate (`@error`) | [§4.5](#45-for-expression) |
| `{ a := x  a + a }` | Block expression: bindings, then a result expression | [§4.12](#412-block-expression) |
| `try r` | The value of a result, or abort with the error's message | [§4.7](#47-try-and-catch) |
| `r catch x`, `r catch \|e\| x` | The value of a result, or the handler's value; the capture is the error value | [§4.7](#47-try-and-catch) |
| `in(path) a else b` | Evaluate in another directory | [§4.11](#411-in-expression) |

### Ranges, Slices and Tuples

| Form | Meaning | See |
|------|---------|-----|
| `for(1..3) \|i\| ...` | Range loop over indices `1, 2` | [§4.9](#49-ranges-and-slices) |
| `for(list, 0..) \|item, i\| ...` | Loop with the element's index | [§4.9](#49-ranges-and-slices) |
| `list[1..3]`, `str[1..]` | Slice (never errors) | [§4.9](#49-ranges-and-slices) |
| `@at(list, 0) catch x` | Single element or character (fails with `out_of_bounds`) | [§5](#5-built-in-functions) |
| `a, b := tuple` | Destructuring binding | [§4.10](#410-tuples-and-destructuring) |
| `for(tuples) \|(a, b)\| ...` | Destructuring capture | [§4.10](#410-tuples-and-destructuring) |

### Working Directory

| Form | Meaning | See |
|------|---------|-----|
| `in(path) { ... } else { ... }` | Statement: run a block in `path`; `else` optional | [§8.9](#89-in-statement) |
| `in(path) expr else expr` | Expression: evaluate in `path`; `else` required | [§4.11](#411-in-expression) |
| `[cwd: "dir"]` on a task or group | Task working directory: `working_dir` + group `cwd` + task `cwd`; independent of the caller | [§12.5](#125-working-directory-attribute) |
| `@cwd()` | Working directory in effect | [§5](#5-built-in-functions) |
| `@invocation_dir()` | Directory tasq was called from | [§5](#5-built-in-functions) |

### Process Calls

| Form | Meaning | See |
|------|---------|-----|
| `` $`cmd` `` | Run a command with the `shell` interpreter; as a statement it aborts on failure, as an expression it is an `error{failed}!string` | [§6](#6-process-calls) |
| `` try $`cmd` ``, `` $`cmd` catch x `` | The captured output as a `string`; abort or replacement on failure | [§6.2](#62-failure-handling) |
| `` $[nofail]`cmd` `` | A non-zero exit is not a failure; as an expression, a plain `string` | [§6.2](#62-failure-handling) |
| `` $[noecho]`cmd` ``, `` $[noecho: false]`cmd` `` | Suppress or force the echo of the command | [§6.3](#63-process-attributes) |
| `` $[script]`...` `` | Run the text as a script file with the `script` interpreter | [§6.4](#64-scripts) |

### Dependencies and Calls

| Form | Meaning | See |
|------|---------|-----|
| `task t [a(), b(1)] { ... }` | Run `a`, then `b(1)`, before the body; sequential, in order | [§8.8](#88-task-dependencies) |
| same task and same arguments, once per call tree | Runs once; later occurrences are skipped | [§8.8](#88-task-dependencies) |
| `a()` as a statement in a body | Always runs; starts a new call tree | [§9](#9-task-calls) |
| `a` depends on `b` and `b` on `a` | Compile-time error (cycles through call statements are not detected) | [§8.8](#88-task-dependencies) |

### Parallel Execution

| Form | Meaning | See |
|------|---------|-----|
| `for(xs) parallel \|x\| expr` | Iterations run concurrently; the result keeps input order; `continue` drops an element; no `break` | [§13.2](#132-parallel-for) |
| `for(xs) parallel(4) \|x\| stmt` | Statement form, at most 4 iterations at once; `continue` ends an iteration; no `break` | [§13.2](#132-parallel-for) |
| `parallel(n) { s1 s2 }` | Statement: every statement is a concurrent branch; braces required | [§13.3](#133-parallel-block) |
| `parallel(n) { a := x  b := y  expr }` | Expression: every binding is a concurrent branch, siblings invisible; the result expression sees them all | [§13.4](#134-parallel-block-expression) |
| `set jobs = 8` | Global budget of threads (a whole number, at least 1); default: number of CPUs | [§7](#7-settings), [§13.1](#131-model-and-limits) |

### Scope Resolution

| Syntax | Resolves to |
|--------|-------------|
| `name(...)` | Nearest enclosing scope |
| `::name(...)` | File root scope |
| `group_name::name(...)` | Specific named group |

---

## 15. Planned Features

Reserved for future versions; not currently part of the language:

- **Precise string units.** `@len`, `@at` and string slices count "characters". The exact unit (Unicode code point, character or glyph) is to be decided and defined precisely ([§4.9](#49-ranges-and-slices), [§5](#5-built-in-functions)).
- **Additional built-in functions**: type conversion utilities and other helpers.
- **Glob errors.** An invalid pattern passed to `@glob` currently results in an empty list ([§5](#5-built-in-functions)). Reporting it as an error may be defined later.
- **Additional settings**: further interpreter configuration options.
- **Additional argument validation attributes.**
- **Script echo.** Scripts are not echoed by default ([§6.4](#64-scripts)); the default may change.
- **Isolated `@status_code()` for static bindings.** Today a lazily evaluated static binding that runs a process updates `@status_code()` like any other process; this may change so that evaluating a static binding leaves it untouched.
- **Eager evaluation of selected static bindings.** A way to force chosen static bindings to be evaluated at startup instead of on first reference.
- **Configurable stdin for process expressions.** They currently read an empty stdin.
- **Dependency identity.** Today a run is identified by the task and its resolved arguments only ([§8.8](#88-task-dependencies)). Two dependencies on the same task with the same arguments count as one run even if they sit under different `[env]` attributes. A future version may make the effective `[env]` part of the identity. (The working directory needs no such handling: it depends only on the task, [§12.5](#125-working-directory-attribute).)
- **Cycle detection for task call statements.** Dependency cycles are rejected at compile time, but cycles through task call statements are not detected today ([§8.8](#88-task-dependencies), [§9](#9-task-calls)). A future version may report them.
- **Parallel dependencies.** An opt-in way to run the dependencies of a task concurrently. Dependencies are always sequential today ([§8.8](#88-task-dependencies)).
- **Output modes for parallel constructs.** Today the output of concurrent branches is neither ordered nor grouped ([§13.7](#137-interaction-with-other-features)). Grouped output (each branch's output printed together when the branch finishes) and line-prefixed live output are being considered, probably selected by a setting.
- **Cancelling running branches on failure.** Today running branches always finish ([§13.5](#135-failure)); stopping them early would require killing their processes.
- **Task label format.** The exact text printed by `task_label` ([§7](#7-settings)) is not specified yet.