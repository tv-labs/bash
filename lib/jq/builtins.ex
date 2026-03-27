defmodule JQ.Builtins do
  @moduledoc """
  Built-in function implementations for the jq language.

  Each builtin is dispatched by name and arity via `call/5`. Filter arguments
  (like the `f` in `map(f)`) are passed as unevaluated AST nodes and executed
  via the provided `eval_fn` callback.
  """

  alias JQ.Error

  @type eval_fn :: (JQ.AST.filter(), term(), JQ.Evaluator.Env.t() -> [term()])

  @doc """
  Dispatches a built-in function call.

  Returns a list of output values (generator semantics).
  Throws `{:jq_error, message}` on errors.
  """
  @spec call(String.t(), [JQ.AST.filter()], term(), JQ.Evaluator.Env.t(), eval_fn()) :: [term()]
  def call(name, args, input, env, eval_fn) do
    do_call(name, args, input, env, eval_fn)
  rescue
    e in [ArithmeticError, ArgumentError] ->
      throw({:jq_error, Exception.message(e)})
  end

  @doc """
  Returns true if `name/arity` is a known builtin.
  """
  @spec has_builtin?(String.t(), non_neg_integer()) :: boolean()
  def has_builtin?(name, arity) do
    {name, arity} in @builtins_list
  end

  defp eval_arg(eval_fn, arg, input, env) do
    case eval_fn.(arg, input, env) do
      [v | _] -> v
      [] -> nil
    end
  end

  defp eval_all(eval_fn, arg, input, env), do: eval_fn.(arg, input, env)

  defp jq_truthy?(false), do: false
  defp jq_truthy?(nil), do: false
  defp jq_truthy?(_), do: true

  # ── type ──

  defp do_call("type", [], input, _env, _eval_fn) do
    [Error.type_name(input)]
  end

  # ── length ──

  defp do_call("length", [], nil, _env, _eval_fn), do: [0]
  defp do_call("length", [], false, _env, _eval_fn), do: [0]
  defp do_call("length", [], true, _env, _eval_fn), do: [1]
  defp do_call("length", [], v, _env, _eval_fn) when is_number(v), do: [abs(v)]
  defp do_call("length", [], v, _env, _eval_fn) when is_binary(v), do: [String.length(v)]
  defp do_call("length", [], v, _env, _eval_fn) when is_list(v), do: [length(v)]
  defp do_call("length", [], v, _env, _eval_fn) when is_map(v), do: [map_size(v)]

  # ── utf8bytelength ──

  defp do_call("utf8bytelength", [], v, _env, _eval_fn) when is_binary(v), do: [byte_size(v)]

  # ── catch-all ──

  defp do_call(name, args, _input, _env, _eval_fn) do
    throw({:jq_error, "#{name}/#{length(args)} is not defined"})
  end

  @builtins_list [
    {"type", 0},
    {"length", 0},
    {"utf8bytelength", 0}
  ]
end
