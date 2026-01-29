defmodule Bash.Statement do
  @moduledoc """
  Type definition for executable Bash statements.

  A statement is any top-level executable construct that can appear
  in a script or command list.
  """

  alias Bash.AST
  alias Bash.Function

  @type t ::
          AST.Command.t()
          | AST.Pipeline.t()
          | AST.Assignment.t()
          | AST.If.t()
          | AST.ForLoop.t()
          | AST.Comment.t()
          | AST.TestCommand.t()
          | AST.TestExpression.t()
          | AST.WhileLoop.t()
          | AST.Case.t()
          | Function.t()
          | AST.Compound.t()
          | AST.Coproc.t()
end
