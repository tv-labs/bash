defmodule JQ.AST do
  @moduledoc "AST node types for jq filters."

  @type filter ::
          Identity.t()
          | RecurseAll.t()
          | Literal.t()
          | Field.t()
          | OptionalField.t()
          | Index.t()
          | Slice.t()
          | Iterate.t()
          | OptionalIterate.t()
          | Pipe.t()
          | Comma.t()
          | ArrayConstruct.t()
          | ObjectConstruct.t()
          | Comparison.t()
          | Arithmetic.t()
          | Negate.t()
          | LogicalAnd.t()
          | LogicalOr.t()
          | LogicalNot.t()
          | StringInterpolation.t()
          | IfThenElse.t()
          | TryCatch.t()
          | Reduce.t()
          | Foreach.t()
          | FuncDef.t()
          | FuncCall.t()
          | Variable.t()
          | Binding.t()
          | PatternBinding.t()
          | Label.t()
          | Break.t()
          | Optional.t()
          | Assign.t()
          | Format.t()

  defmodule Identity do
    @moduledoc "The identity filter `.`."
    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule RecurseAll do
    @moduledoc "The recursive descent filter `..`."
    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule Literal do
    @moduledoc "A literal value: null, true, false, number, or string."
    @type t :: %__MODULE__{value: nil | boolean() | number() | String.t()}
    defstruct [:value]
  end

  defmodule Field do
    @moduledoc "Field access `.foo` or `.[\"foo\"]`."
    @type t :: %__MODULE__{name: String.t()}
    defstruct [:name]
  end

  defmodule OptionalField do
    @moduledoc "Optional field access `.foo?`."
    @type t :: %__MODULE__{name: String.t()}
    defstruct [:name]
  end

  defmodule Index do
    @moduledoc "Index access `.[expr]`."
    @type t :: %__MODULE__{expr: JQ.AST.filter()}
    defstruct [:expr]
  end

  defmodule Slice do
    @moduledoc "Slice access `.[from:to]`."
    @type t :: %__MODULE__{from: JQ.AST.filter() | nil, to: JQ.AST.filter() | nil}
    defstruct [:from, :to]
  end

  defmodule Iterate do
    @moduledoc "Value iterator `.[]`."
    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule OptionalIterate do
    @moduledoc "Optional value iterator `.[]?`."
    @type t :: %__MODULE__{}
    defstruct []
  end

  defmodule Pipe do
    @moduledoc "Pipe composition `left | right`."
    @type t :: %__MODULE__{left: JQ.AST.filter(), right: JQ.AST.filter()}
    defstruct [:left, :right]
  end

  defmodule Comma do
    @moduledoc "Comma operator producing multiple outputs `left, right`."
    @type t :: %__MODULE__{left: JQ.AST.filter(), right: JQ.AST.filter()}
    defstruct [:left, :right]
  end

  defmodule ArrayConstruct do
    @moduledoc "Array construction `[filter]`."
    @type t :: %__MODULE__{expr: JQ.AST.filter() | nil}
    defstruct [:expr]
  end

  defmodule ObjectConstruct do
    @moduledoc "Object construction `{key: value, ...}`."
    @type t :: %__MODULE__{pairs: [{JQ.AST.filter(), JQ.AST.filter()}]}
    defstruct [pairs: []]
  end

  defmodule Comparison do
    @moduledoc "Comparison operators `==`, `!=`, `<`, `>`, `<=`, `>=`."
    @type t :: %__MODULE__{
            op: :eq | :neq | :lt | :gt | :lte | :gte,
            left: JQ.AST.filter(),
            right: JQ.AST.filter()
          }
    defstruct [:op, :left, :right]
  end

  defmodule Arithmetic do
    @moduledoc "Arithmetic operators `+`, `-`, `*`, `/`, `%`."
    @type t :: %__MODULE__{
            op: :add | :sub | :mul | :div | :mod,
            left: JQ.AST.filter(),
            right: JQ.AST.filter()
          }
    defstruct [:op, :left, :right]
  end

  defmodule Negate do
    @moduledoc "Unary negation `-filter`."
    @type t :: %__MODULE__{expr: JQ.AST.filter()}
    defstruct [:expr]
  end

  defmodule LogicalAnd do
    @moduledoc "Logical conjunction `and`."
    @type t :: %__MODULE__{left: JQ.AST.filter(), right: JQ.AST.filter()}
    defstruct [:left, :right]
  end

  defmodule LogicalOr do
    @moduledoc "Logical disjunction `or`."
    @type t :: %__MODULE__{left: JQ.AST.filter(), right: JQ.AST.filter()}
    defstruct [:left, :right]
  end

  defmodule LogicalNot do
    @moduledoc "Logical negation `not`."
    @type t :: %__MODULE__{expr: JQ.AST.filter()}
    defstruct [:expr]
  end

  defmodule StringInterpolation do
    @moduledoc "String interpolation `\"hello \\(name)\"`."
    @type t :: %__MODULE__{parts: [{:literal, String.t()} | {:interp, JQ.AST.filter()}]}
    defstruct [parts: []]
  end

  defmodule IfThenElse do
    @moduledoc "Conditional `if cond then body elif ... else ... end`."
    @type t :: %__MODULE__{
            condition: JQ.AST.filter(),
            then_branch: JQ.AST.filter(),
            elifs: [{JQ.AST.filter(), JQ.AST.filter()}],
            else_branch: JQ.AST.filter() | nil
          }
    defstruct [:condition, :then_branch, elifs: [], else_branch: nil]
  end

  defmodule TryCatch do
    @moduledoc "Error handling `try-catch`."
    @type t :: %__MODULE__{try_expr: JQ.AST.filter(), catch_expr: JQ.AST.filter() | nil}
    defstruct [:try_expr, :catch_expr]
  end

  defmodule Reduce do
    @moduledoc "Reduction `reduce expr as $var (init; update)`."
    @type t :: %__MODULE__{
            expr: JQ.AST.filter(),
            var: String.t(),
            init: JQ.AST.filter(),
            update: JQ.AST.filter()
          }
    defstruct [:expr, :var, :init, :update]
  end

  defmodule Foreach do
    @moduledoc "Iteration `foreach expr as $var (init; update; extract)`."
    @type t :: %__MODULE__{
            expr: JQ.AST.filter(),
            var: String.t(),
            init: JQ.AST.filter(),
            update: JQ.AST.filter(),
            extract: JQ.AST.filter() | nil
          }
    defstruct [:expr, :var, :init, :update, :extract]
  end

  defmodule FuncDef do
    @moduledoc "Function definition `def name(params): body;`."
    @type t :: %__MODULE__{
            name: String.t(),
            params: [String.t()],
            body: JQ.AST.filter(),
            next: JQ.AST.filter()
          }
    defstruct [:name, params: [], :body, :next]
  end

  defmodule FuncCall do
    @moduledoc "Function call `name(args)`."
    @type t :: %__MODULE__{name: String.t(), args: [JQ.AST.filter()]}
    defstruct [:name, args: []]
  end

  defmodule Variable do
    @moduledoc "Variable reference `$var`."
    @type t :: %__MODULE__{name: String.t()}
    defstruct [:name]
  end

  defmodule Binding do
    @moduledoc "Variable binding `expr as $var | body`."
    @type t :: %__MODULE__{
            expr: JQ.AST.filter(),
            var: String.t(),
            body: JQ.AST.filter()
          }
    defstruct [:expr, :var, :body]
  end

  defmodule PatternBinding do
    @moduledoc "Destructuring binding `expr as {a, $b, c} | body`."
    @type t :: %__MODULE__{
            expr: JQ.AST.filter(),
            patterns: [term()],
            body: JQ.AST.filter()
          }
    defstruct [:expr, :patterns, :body]
  end

  defmodule Label do
    @moduledoc "Label for break target `label $name | body`."
    @type t :: %__MODULE__{name: String.t(), body: JQ.AST.filter()}
    defstruct [:name, :body]
  end

  defmodule Break do
    @moduledoc "Break out of labeled scope `break $name`."
    @type t :: %__MODULE__{name: String.t()}
    defstruct [:name]
  end

  defmodule Optional do
    @moduledoc "Optional operator `filter?`."
    @type t :: %__MODULE__{expr: JQ.AST.filter()}
    defstruct [:expr]
  end

  defmodule Assign do
    @moduledoc "Assignment operators `=`, `|=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=`."
    @type t :: %__MODULE__{
            path: JQ.AST.filter(),
            op: :assign | :update | :add | :sub | :mul | :div | :mod | :alt,
            value: JQ.AST.filter()
          }
    defstruct [:path, :op, :value]
  end

  defmodule Format do
    @moduledoc "Format string `@base64`, `@html`, etc."
    @type t :: %__MODULE__{name: String.t(), expr: JQ.AST.filter() | nil}
    defstruct [:name, :expr]
  end
end
