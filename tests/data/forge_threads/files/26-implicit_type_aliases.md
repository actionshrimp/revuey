```

We *do* support stringified annotations if they appear in a position where a type expression is
syntactically expected:

```py
from typing import Union, List, Dict, Annotated, Callable

ListOfInts1 = list["int"]
ListOfInts2 = List["int"]
StrOrStyle = Union[str, "Style"]
SubclassOfStyle = type["Style"]
DictStrToStyle = Dict[str, "Style"]
AnnotatedStyle = Annotated["Style", "metadata"]
CallableStyleToStyle = Callable[["Style"], "Style"]

class Style: ...

def _(
    list_of_ints1: ListOfInts1,
    list_of_ints2: ListOfInts2,
    str_or_style: StrOrStyle,
    subclass_of_style: SubclassOfStyle,
    dict_str_to_style: DictStrToStyle,
    annotated_style: AnnotatedStyle,
    callable_style_to_style: CallableStyleToStyle,
):
    reveal_type(list_of_ints1)  # revealed: list[int]
    reveal_type(list_of_ints2)  # revealed: list[int]
    reveal_type(str_or_style)  # revealed: str | Style
    reveal_type(subclass_of_style)  # revealed: type[Style]
    reveal_type(dict_str_to_style)  # revealed: dict[str, Style]
    reveal_type(annotated_style)  # revealed: Style
    reveal_type(callable_style_to_style)  # revealed: (Style, /) -> Style
```

## Ordinary assignments remain values

An assignment that is never used in a type expression is not checked as a type alias. In particular,
`Self` can be stored as a value, and a list of classes is an ordinary list.

```py
from typing_extensions import Self

class Node:
    marker = Self
    classes = [int, str]
```

## Invalid implicit aliases

A valid runtime expression can still be invalid as a type expression. We reject using such a value
as an annotation, rather than reporting an error on its ordinary assignment:

```py
Number = 1 + 2
one = 1
ForwardedNumber = one

def inspect(
    expression: Number,  # snapshot: invalid-type-form
    forwarded: ForwardedNumber,  # error: [invalid-type-form]
    specialized: Number[int],  # error: [invalid-type-form]
    quoted: "Number",  # error: [invalid-type-form]
):
    reveal_type(expression)  # revealed: Unknown
    reveal_type(forwarded)  # revealed: Unknown
    reveal_type(specialized)  # revealed: Unknown
    reveal_type(quoted)  # revealed: Unknown
```

```snapshot
error[invalid-type-form]: Variable `Number` cannot be used as a type
 --> src/mdtest_snippet.py:6:17
  |
6 |     expression: Number,  # snapshot: invalid-type-form
  |                 ^^^^^^
info: `Number` is not a valid type alias
info: Invalid binary operator `+` in a type alias definition
 --> src/mdtest_snippet.py:1:10
  |
1 | Number = 1 + 2
  |          ^^^^^
info: See the following page for a reference on valid type expressions:
info: https://typing.python.org/en/latest/spec/annotations.html#type-and-annotation-expressions
```

An expression that evaluates to a class does not automatically define a type alias. The diagnostic
explains why its original definition is invalid as a type expression:

```py
Called = type(1)

# snapshot: invalid-type-form
def inspect(called: Called):
    reveal_type(called)  # revealed: Unknown
```

```snapshot
error[invalid-type-form]: Variable `Called` cannot be used as a type
  --> src/mdtest_snippet.py:18:21
   |
18 | def inspect(called: Called):
   |                     ^^^^^^
info: `Called` is not a valid type alias
info: Function calls are not allowed in type alias definitions
  --> src/mdtest_snippet.py:15:10
   |
15 | Called = type(1)
   |          ^^^^^^^
info: See the following page for a reference on valid type expressions:
info: https://typing.python.org/en/latest/spec/annotations.html#type-and-annotation-expressions
```

Other calls, indexing into a list or dictionary, conditional expressions, and boolean operations
also remain ordinary values, even if they evaluate to a class or `Any`. Assigning such a value to
another name does not make it a type alias:

```py
Evaluated = eval("int")
CalledGeneric = (lambda: list)()
Indexed = [int][0]
Classes = [int]
IndexedName = Classes[0]
Mixed = [int, 1]
IndexedMixed = Mixed[0]
Mapping = {"type": int}
IndexedMapping = Mapping["type"]
Conditional = int if 1 < 3 else str
Boolean = list or set
ForwardedCalled = Called

def inspect(
    evaluated: Evaluated,  # error: [invalid-type-form]
    specialized: CalledGeneric[int],  # error: [invalid-type-form]
    indexed: Indexed,  # error: [invalid-type-form]
    indexed_name: IndexedName,  # error: [invalid-type-form]
    indexed_mixed: IndexedMixed,  # error: [invalid-type-form]
    indexed_mapping: IndexedMapping,  # error: [invalid-type-form]
    conditional: Conditional,  # error: [invalid-type-form]
    boolean: Boolean,  # error: [invalid-type-form]
    forwarded: ForwardedCalled,  # error: [invalid-type-form]
):
    reveal_type(evaluated)  # revealed: Unknown
    reveal_type(specialized)  # revealed: Unknown
    reveal_type(indexed_mixed)  # revealed: Unknown
```

Errors in type arguments remain visible even when the alias itself is invalid:

```py
def invalid_arguments(
    # error: [invalid-type-form]
    # error: [unresolved-reference]
    single: CalledGeneric[Missing],
    # error: [invalid-type-form]
    # error: [unresolved-reference]
    multiple: CalledGeneric[int, Missing],
    # error: [invalid-type-form]
    # error: [unsupported-operator]
    computed: CalledGeneric[1 + "bad"],
): ...
```

Invalid aliases in string annotations also recover without evaluating nested runtime expressions:

```py
def invalid_string(value: "CalledGeneric[lambda: int]"): ...  # error: [invalid-type-form]
```

## Invalid expressions with nested scopes

Lambdas and comprehensions are invalid type arguments, even when they refer to type variables:

```py
from typing import TypeVar

T = TypeVar("T")
LambdaAlias = list[lambda: T]  # error: [invalid-type-form]
ComprehensionAlias = list[[T for _ in []]]  # error: [invalid-type-form]

def inspect(lambda_alias: LambdaAlias, comprehension_alias: ComprehensionAlias):
    reveal_type(lambda_alias)  # revealed: list[Unknown]
    reveal_type(comprehension_alias)  # revealed: list[Unknown]
```

## Imported invalid implicit aliases

Importing a value, accessing it through its module, or assigning it to another name does not make it
a valid type alias, even when the value is a class. This also holds when the defining module is a
dependency that is not checked:

```toml
[environment]
extra-paths = ["/dependencies"]
```

`/dependencies/values.py`:

```py
Number = 1 + 2
Forwarded = Number
ComputedClass = (lambda: int)()
ForwardedClass = ComputedClass
```

`main.py`:

```py
from values import ForwardedClass

# snapshot: invalid-type-form
def inspect_forwarded(forwarded: ForwardedClass):
    reveal_type(forwarded)  # revealed: Unknown
```

```snapshot
error[invalid-type-form]: Variable `ForwardedClass` cannot be used as a type
 --> src/main.py:4:34
  |
4 | def inspect_forwarded(forwarded: ForwardedClass):
