defmodule AWK.AST do
  @moduledoc """
  AST node types for the AWK interpreter.

  Every AWK language construct is represented as a struct nested under this module.
  Nodes are grouped into program structure, patterns, statements, expressions,
  function definitions, and output redirection.
  """

  # ---------------------------------------------------------------------------
  # Type unions
  # ---------------------------------------------------------------------------

  @typedoc "Any pattern node."
  @type pattern ::
          ExprPattern.t()
          | RegexPattern.t()
          | RangePattern.t()

  @typedoc "Any statement node."
  @type statement ::
          Block.t()
          | ExprStmt.t()
          | PrintStmt.t()
          | PrintfStmt.t()
          | IfStmt.t()
          | WhileStmt.t()
          | DoWhileStmt.t()
          | ForStmt.t()
          | ForInStmt.t()
          | BreakStmt.t()
          | ContinueStmt.t()
          | NextStmt.t()
          | NextfileStmt.t()
          | ExitStmt.t()
          | ReturnStmt.t()
          | DeleteStmt.t()
          | GetlineStmt.t()

  @typedoc "Any expression node."
  @type expression ::
          NumberLiteral.t()
          | StringLiteral.t()
          | RegexLiteral.t()
          | FieldRef.t()
          | Variable.t()
          | ArrayRef.t()
          | Assignment.t()
          | UnaryExpr.t()
          | BinaryExpr.t()
          | TernaryExpr.t()
          | MatchExpr.t()
          | InExpr.t()
          | PreIncrement.t()
          | PreDecrement.t()
          | PostIncrement.t()
          | PostDecrement.t()
          | Concatenation.t()
          | FuncCall.t()
          | GetlineExpr.t()
          | PipeGetline.t()
          | GroupExpr.t()
          | UnaryPlus.t()
          | UnaryMinus.t()
          | UnaryNot.t()

  @typedoc "Any AST node."
  @type node ::
          Program.t()
          | Rule.t()
          | BeginRule.t()
          | EndRule.t()
          | BeginfileRule.t()
          | EndfileRule.t()
          | FuncDef.t()
          | OutputRedirect.t()
          | pattern()
          | statement()
          | expression()

  # ---------------------------------------------------------------------------
  # Program structure
  # ---------------------------------------------------------------------------

  defmodule Program do
    @moduledoc "Top-level AWK program."

    @type t :: %__MODULE__{
            begin_rules: [AWK.AST.BeginRule.t()],
            rules: [AWK.AST.Rule.t()],
            end_rules: [AWK.AST.EndRule.t()],
            functions: [AWK.AST.FuncDef.t()]
          }

    defstruct begin_rules: [], rules: [], end_rules: [], functions: []
  end

  defmodule Rule do
    @moduledoc "A pattern-action rule."

    @type t :: %__MODULE__{
            pattern: AWK.AST.pattern() | nil,
            action: AWK.AST.Block.t() | nil
          }

    defstruct [:pattern, :action]
  end

  defmodule BeginRule do
    @moduledoc "BEGIN { action } rule, executed before input processing."

    @type t :: %__MODULE__{action: AWK.AST.Block.t()}

    defstruct [:action]
  end

  defmodule EndRule do
    @moduledoc "END { action } rule, executed after input processing."

    @type t :: %__MODULE__{action: AWK.AST.Block.t()}

    defstruct [:action]
  end

  defmodule BeginfileRule do
    @moduledoc "BEGINFILE { action } rule, executed before each input file."

    @type t :: %__MODULE__{action: AWK.AST.Block.t()}

    defstruct [:action]
  end

  defmodule EndfileRule do
    @moduledoc "ENDFILE { action } rule, executed after each input file."

    @type t :: %__MODULE__{action: AWK.AST.Block.t()}

    defstruct [:action]
  end

  # ---------------------------------------------------------------------------
  # Patterns
  # ---------------------------------------------------------------------------

  defmodule ExprPattern do
    @moduledoc "An expression used as a pattern; truthy values match."

    @type t :: %__MODULE__{expr: AWK.AST.expression()}

    defstruct [:expr]
  end

  defmodule RegexPattern do
    @moduledoc "/regex/ pattern that matches against $0."

    @type t :: %__MODULE__{regex: String.t()}

    defstruct [:regex]
  end

  defmodule RangePattern do
    @moduledoc "Range pattern: pattern1, pattern2. Matches from first to second."

    @type t :: %__MODULE__{
            from: AWK.AST.pattern(),
            to: AWK.AST.pattern()
          }

    defstruct [:from, :to]
  end

  # ---------------------------------------------------------------------------
  # Statements
  # ---------------------------------------------------------------------------

  defmodule Block do
    @moduledoc "A brace-delimited list of statements."

    @type t :: %__MODULE__{statements: [AWK.AST.statement()]}

    defstruct statements: []
  end

  defmodule ExprStmt do
    @moduledoc "An expression used as a statement."

    @type t :: %__MODULE__{expr: AWK.AST.expression()}

    defstruct [:expr]
  end

  defmodule PrintStmt do
    @moduledoc "print [expr, ...] [redirect]"

    @type t :: %__MODULE__{
            args: [AWK.AST.expression()],
            redirect: AWK.AST.OutputRedirect.t() | nil
          }

    defstruct args: [], redirect: nil
  end

  defmodule PrintfStmt do
    @moduledoc "printf format [, expr, ...] [redirect]"

    @type t :: %__MODULE__{
            format: AWK.AST.expression(),
            args: [AWK.AST.expression()],
            redirect: AWK.AST.OutputRedirect.t() | nil
          }

    defstruct [:format, args: [], redirect: nil]
  end

  defmodule IfStmt do
    @moduledoc "if (condition) consequent [else alternative]"

    @type t :: %__MODULE__{
            condition: AWK.AST.expression(),
            consequent: AWK.AST.statement(),
            alternative: AWK.AST.statement() | nil
          }

    defstruct [:condition, :consequent, :alternative]
  end

  defmodule WhileStmt do
    @moduledoc "while (condition) body"

    @type t :: %__MODULE__{
            condition: AWK.AST.expression(),
            body: AWK.AST.statement()
          }

    defstruct [:condition, :body]
  end

  defmodule DoWhileStmt do
    @moduledoc "do body while (condition)"

    @type t :: %__MODULE__{
            body: AWK.AST.statement(),
            condition: AWK.AST.expression()
          }

    defstruct [:body, :condition]
  end

  defmodule ForStmt do
    @moduledoc "for (init; condition; increment) body"

    @type t :: %__MODULE__{
            init: AWK.AST.statement() | nil,
            condition: AWK.AST.expression() | nil,
            increment: AWK.AST.expression() | nil,
            body: AWK.AST.statement()
          }

    defstruct [:init, :condition, :increment, :body]
  end

  defmodule ForInStmt do
    @moduledoc "for (var in array) body"

    @type t :: %__MODULE__{
            variable: String.t(),
            array: String.t(),
            body: AWK.AST.statement()
          }

    defstruct [:variable, :array, :body]
  end

  defmodule BreakStmt do
    @moduledoc "break statement."

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule ContinueStmt do
    @moduledoc "continue statement."

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule NextStmt do
    @moduledoc "next statement; skip to the next input record."

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule NextfileStmt do
    @moduledoc "nextfile statement; skip to the next input file."

    @type t :: %__MODULE__{}

    defstruct []
  end

  defmodule ExitStmt do
    @moduledoc "exit [expr] statement."

    @type t :: %__MODULE__{status: AWK.AST.expression() | nil}

    defstruct [:status]
  end

  defmodule ReturnStmt do
    @moduledoc "return [expr] statement."

    @type t :: %__MODULE__{value: AWK.AST.expression() | nil}

    defstruct [:value]
  end

  defmodule DeleteStmt do
    @moduledoc "delete array[idx] or delete array."

    @type t :: %__MODULE__{
            target: AWK.AST.ArrayRef.t() | AWK.AST.Variable.t()
          }

    defstruct [:target]
  end

  defmodule GetlineStmt do
    @moduledoc "getline [var] [< file] or cmd | getline [var] as a statement."

    @type t :: %__MODULE__{
            variable: String.t() | nil,
            source: AWK.AST.expression() | nil,
            command: AWK.AST.expression() | nil
          }

    defstruct [:variable, :source, :command]
  end

  # ---------------------------------------------------------------------------
  # Expressions
  # ---------------------------------------------------------------------------

  defmodule NumberLiteral do
    @moduledoc "Numeric constant."

    @type t :: %__MODULE__{value: number()}

    defstruct [:value]
  end

  defmodule StringLiteral do
    @moduledoc "String constant."

    @type t :: %__MODULE__{value: String.t()}

    defstruct [:value]
  end

  defmodule RegexLiteral do
    @moduledoc "/regex/ in expression context."

    @type t :: %__MODULE__{value: String.t()}

    defstruct [:value]
  end

  defmodule FieldRef do
    @moduledoc "$expr field reference."

    @type t :: %__MODULE__{expr: AWK.AST.expression()}

    defstruct [:expr]
  end

  defmodule Variable do
    @moduledoc "Unqualified variable name."

    @type t :: %__MODULE__{name: String.t()}

    defstruct [:name]
  end

  defmodule ArrayRef do
    @moduledoc "array[expr] or array[expr, expr, ...] subscript access."

    @type t :: %__MODULE__{
            name: String.t(),
            indices: [AWK.AST.expression()]
          }

    defstruct [:name, indices: []]
  end

  defmodule Assignment do
    @moduledoc "lvalue op= expr assignment."

    @type t :: %__MODULE__{
            target: AWK.AST.expression(),
            op: :eq | :plus_eq | :minus_eq | :times_eq | :div_eq | :mod_eq | :pow_eq,
            value: AWK.AST.expression()
          }

    defstruct [:target, :op, :value]
  end

  defmodule UnaryExpr do
    @moduledoc "Unary expression: -expr, +expr, !expr."

    @type t :: %__MODULE__{
            op: :minus | :plus | :not,
            operand: AWK.AST.expression()
          }

    defstruct [:op, :operand]
  end

  defmodule BinaryExpr do
    @moduledoc "Binary expression covering arithmetic, comparison, and logical operators."

    @type t :: %__MODULE__{
            op:
              :add
              | :subtract
              | :multiply
              | :divide
              | :modulo
              | :power
              | :less
              | :less_eq
              | :equal
              | :not_equal
              | :greater_eq
              | :greater
              | :and
              | :or,
            left: AWK.AST.expression(),
            right: AWK.AST.expression()
          }

    defstruct [:op, :left, :right]
  end

  defmodule TernaryExpr do
    @moduledoc "cond ? true_expr : false_expr"

    @type t :: %__MODULE__{
            condition: AWK.AST.expression(),
            consequent: AWK.AST.expression(),
            alternative: AWK.AST.expression()
          }

    defstruct [:condition, :consequent, :alternative]
  end

  defmodule MatchExpr do
    @moduledoc "expr ~ regex or expr !~ regex"

    @type t :: %__MODULE__{
            expr: AWK.AST.expression(),
            regex: AWK.AST.expression(),
            negate: boolean()
          }

    defstruct [:expr, :regex, negate: false]
  end

  defmodule InExpr do
    @moduledoc "(idx) in array membership test."

    @type t :: %__MODULE__{
            index: [AWK.AST.expression()],
            array: String.t()
          }

    defstruct [:index, :array]
  end

  defmodule PreIncrement do
    @moduledoc "++var pre-increment."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  defmodule PreDecrement do
    @moduledoc "--var pre-decrement."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  defmodule PostIncrement do
    @moduledoc "var++ post-increment."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  defmodule PostDecrement do
    @moduledoc "var-- post-decrement."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  defmodule Concatenation do
    @moduledoc "Implicit string concatenation of two adjacent expressions."

    @type t :: %__MODULE__{
            left: AWK.AST.expression(),
            right: AWK.AST.expression()
          }

    defstruct [:left, :right]
  end

  defmodule FuncCall do
    @moduledoc "function(args) call expression."

    @type t :: %__MODULE__{
            name: String.t(),
            args: [AWK.AST.expression()]
          }

    defstruct [:name, args: []]
  end

  defmodule GetlineExpr do
    @moduledoc "getline as an expression: getline [var] [< file]."

    @type t :: %__MODULE__{
            variable: String.t() | nil,
            source: AWK.AST.expression() | nil
          }

    defstruct [:variable, :source]
  end

  defmodule PipeGetline do
    @moduledoc "cmd | getline [var] pipe expression."

    @type t :: %__MODULE__{
            command: AWK.AST.expression(),
            variable: String.t() | nil
          }

    defstruct [:command, :variable]
  end

  defmodule GroupExpr do
    @moduledoc "(expr) parenthesized expression."

    @type t :: %__MODULE__{expr: AWK.AST.expression()}

    defstruct [:expr]
  end

  defmodule UnaryPlus do
    @moduledoc "Unary plus: +expr."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  defmodule UnaryMinus do
    @moduledoc "Unary minus: -expr."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  defmodule UnaryNot do
    @moduledoc "Logical not: !expr."

    @type t :: %__MODULE__{operand: AWK.AST.expression()}

    defstruct [:operand]
  end

  # ---------------------------------------------------------------------------
  # Function definition
  # ---------------------------------------------------------------------------

  defmodule FuncDef do
    @moduledoc "function name(params) { body }"

    @type t :: %__MODULE__{
            name: String.t(),
            params: [String.t()],
            body: AWK.AST.Block.t()
          }

    defstruct [:name, params: [], body: nil]
  end

  # ---------------------------------------------------------------------------
  # Output redirection
  # ---------------------------------------------------------------------------

  defmodule OutputRedirect do
    @moduledoc "Output redirection for print/printf: > file, >> file, or | cmd."

    @type t :: %__MODULE__{
            type: :write | :append | :pipe,
            target: AWK.AST.expression()
          }

    defstruct [:type, :target]
  end
end
