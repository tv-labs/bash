defmodule JQ.Evaluator do
  @moduledoc """
  Streaming evaluator for jq filter ASTs.

  Each jq filter is a generator: given one input value, it produces zero or
  more output values. The evaluator walks the AST and applies this generator
  semantics throughout.

  ## Streaming

  The evaluator supports two modes:

    * `eval/3` — eager evaluation returning a list of results
    * `eval_stream/3` — lazy evaluation over a stream of inputs using
      `Stream.flat_map/2`, never accumulating the full input in memory

  ```mermaid
  graph LR
      A[Input Value] --> B[Filter AST]
      B --> C{Generator}
      C -->|0..N| D[Output Values]
  ```
  """

  alias JQ.AST
  alias JQ.AST.{
    Identity,
    RecurseAll,
    Literal,
    Field,
    OptionalField,
    Index,
    Slice,
    Iterate,
    OptionalIterate,
    Pipe,
    Comma,
    ArrayConstruct,
    ObjectConstruct,
    Comparison,
    Arithmetic,
    Negate,
    LogicalAnd,
    LogicalOr,
    LogicalNot,
    StringInterpolation,
    IfThenElse,
    TryCatch,
    Reduce,
    Foreach,
    FuncDef,
    FuncCall,
    Variable,
    Binding,
    PatternBinding,
    Label,
    Break,
    Optional,
    Assign,
    Format
  }

  alias JQ.Error

  defmodule Env do
    @moduledoc "Evaluation environment with variable bindings and function definitions."

    @type func_def :: %{params: [String.t()], body: JQ.AST.filter(), env: t()}
    @type t :: %__MODULE__{
            bindings: %{String.t() => term()},
            functions: %{{String.t(), non_neg_integer()} => func_def()}
          }

    defstruct bindings: %{}, functions: %{}
  end

  @doc """
  Evaluates a filter against a single input value.

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec eval(AST.filter(), term(), Env.t()) :: {:ok, [term()]} | {:error, term()}
  def eval(filter, input, env \\ %Env{}) do
    try do
      {:ok, do_eval(filter, input, env)}
    catch
      {:jq_error, msg} -> {:error, msg}
      {:jq_halt, code} -> {:error, {:halt, code}}
    end
  end

  @doc """
  Applies a filter to a stream of inputs, producing a lazy stream of outputs.

  Each input value is independently evaluated through the filter, and all
  outputs are concatenated lazily. No intermediate results are accumulated
  beyond what the filter itself requires (e.g. `[.[] | f]` must collect).
  """
  @spec eval_stream(AST.filter(), Enumerable.t(), Env.t()) :: Enumerable.t()
  def eval_stream(filter, input_stream, env \\ %Env{}) do
    Stream.flat_map(input_stream, fn input ->
      case eval(filter, input, env) do
        {:ok, results} -> results
        {:error, _} -> []
      end
    end)
  end

  # ── Identity ──────────────────────────────────────────────────────────

  defp do_eval(%Identity{}, input, _env), do: [input]

  # ── Recursive Descent ─────────────────────────────────────────────────

  defp do_eval(%RecurseAll{}, input, _env), do: recurse_all(input)

  defp recurse_all(v) when is_map(v) do
    [v | Enum.flat_map(Map.values(v), &recurse_all/1)]
  end

  defp recurse_all(v) when is_list(v) do
    [v | Enum.flat_map(v, &recurse_all/1)]
  end

  defp recurse_all(v), do: [v]

  # ── Literal ───────────────────────────────────────────────────────────

  defp do_eval(%Literal{value: v}, _input, _env), do: [v]

  # ── Field Access ──────────────────────────────────────────────────────

  defp do_eval(%Field{name: name}, input, _env) when is_map(input) do
    [Map.get(input, name)]
  end

  defp do_eval(%Field{}, nil, _env), do: [nil]

  defp do_eval(%Field{name: name}, input, _env) do
    throw({:jq_error, "null (#{Error.type_name(input)}) and string (\"#{name}\") cannot be iterated over"})
  end

  # ── Optional Field ────────────────────────────────────────────────────

  defp do_eval(%OptionalField{name: name}, input, _env) when is_map(input) do
    [Map.get(input, name)]
  end

  defp do_eval(%OptionalField{}, nil, _env), do: [nil]
  defp do_eval(%OptionalField{}, _input, _env), do: []

  # ── Index ─────────────────────────────────────────────────────────────

  defp do_eval(%Index{expr: expr}, input, env) do
    Enum.flat_map(do_eval(expr, input, env), fn idx ->
      [index_into(input, idx)]
    end)
  end

  defp index_into(list, idx) when is_list(list) and is_integer(idx) do
    idx = if idx < 0, do: length(list) + idx, else: idx
    Enum.at(list, idx)
  end

  defp index_into(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)
  defp index_into(nil, _), do: nil

  defp index_into(input, idx) do
    throw({:jq_error, "cannot index #{Error.type_name(input)} with #{Error.type_name(idx)}"})
  end

  # ── Slice ─────────────────────────────────────────────────────────────

  defp do_eval(%Slice{from: from_expr, to: to_expr}, input, env) when is_list(input) do
    len = length(input)
    from = resolve_slice_bound(from_expr, input, env, 0, len)
    to = resolve_slice_bound(to_expr, input, env, len, len)
    [Enum.slice(input, from, max(to - from, 0))]
  end

  defp do_eval(%Slice{from: from_expr, to: to_expr}, input, env) when is_binary(input) do
    len = String.length(input)
    from = resolve_slice_bound(from_expr, input, env, 0, len)
    to = resolve_slice_bound(to_expr, input, env, len, len)
    [String.slice(input, from, max(to - from, 0))]
  end

  defp do_eval(%Slice{}, nil, _env), do: [nil]

  defp do_eval(%Slice{}, input, _env) do
    throw({:jq_error, "cannot slice #{Error.type_name(input)}"})
  end

  defp resolve_slice_bound(nil, _input, _env, default, _len), do: default

  defp resolve_slice_bound(expr, input, env, _default, len) do
    case do_eval(expr, input, env) do
      [n | _] when is_integer(n) -> if n < 0, do: max(len + n, 0), else: min(n, len)
      _ -> 0
    end
  end

  # ── Iterate ───────────────────────────────────────────────────────────

  defp do_eval(%Iterate{}, input, _env) when is_list(input), do: input

  defp do_eval(%Iterate{}, input, _env) when is_map(input), do: Map.values(input)

  defp do_eval(%Iterate{}, input, _env) do
    throw({:jq_error, "cannot iterate over #{Error.type_name(input)}"})
  end

  defp do_eval(%OptionalIterate{}, input, _env) when is_list(input), do: input
  defp do_eval(%OptionalIterate{}, input, _env) when is_map(input), do: Map.values(input)
  defp do_eval(%OptionalIterate{}, _input, _env), do: []

  # ── Pipe ──────────────────────────────────────────────────────────────

  defp do_eval(%Pipe{left: left, right: right}, input, env) do
    Enum.flat_map(do_eval(left, input, env), fn lv ->
      do_eval(right, lv, env)
    end)
  end

  # ── Comma ─────────────────────────────────────────────────────────────

  defp do_eval(%Comma{left: left, right: right}, input, env) do
    do_eval(left, input, env) ++ do_eval(right, input, env)
  end

  # ── Array Construction ────────────────────────────────────────────────

  defp do_eval(%ArrayConstruct{expr: nil}, _input, _env), do: [[]]

  defp do_eval(%ArrayConstruct{expr: expr}, input, env) do
    [do_eval(expr, input, env)]
  end

  # ── Object Construction ───────────────────────────────────────────────

  defp do_eval(%ObjectConstruct{pairs: pairs}, input, env) do
    build_objects(pairs, input, env, [%{}])
  end

  defp build_objects([], _input, _env, acc), do: acc

  defp build_objects([{key_expr, val_expr} | rest], input, env, acc) do
    keys = do_eval(key_expr, input, env)
    vals = do_eval(val_expr, input, env)

    new_acc =
      for obj <- acc, k <- keys, v <- vals do
        Map.put(obj, jq_tostring(k), v)
      end

    build_objects(rest, input, env, new_acc)
  end

  # ── Comparison ────────────────────────────────────────────────────────

  defp do_eval(%Comparison{op: op, left: left, right: right}, input, env) do
    for lv <- do_eval(left, input, env),
        rv <- do_eval(right, input, env) do
      case op do
        :eq -> lv == rv
        :neq -> lv != rv
        :lt -> jq_compare(lv, rv) == :lt
        :gt -> jq_compare(lv, rv) == :gt
        :lte -> jq_compare(lv, rv) in [:lt, :eq]
        :gte -> jq_compare(lv, rv) in [:gt, :eq]
      end
    end
  end

  # ── Arithmetic ────────────────────────────────────────────────────────

  defp do_eval(%Arithmetic{op: op, left: left, right: right}, input, env) do
    for lv <- do_eval(left, input, env),
        rv <- do_eval(right, input, env) do
      jq_arith(op, lv, rv)
    end
  end

  defp jq_arith(:add, nil, r), do: r
  defp jq_arith(:add, l, nil), do: l
  defp jq_arith(:add, l, r) when is_number(l) and is_number(r), do: l + r
  defp jq_arith(:add, l, r) when is_binary(l) and is_binary(r), do: l <> r
  defp jq_arith(:add, l, r) when is_list(l) and is_list(r), do: l ++ r
  defp jq_arith(:add, l, r) when is_map(l) and is_map(r), do: Map.merge(l, r)

  defp jq_arith(:add, l, r) do
    throw({:jq_error, "#{Error.type_name(l)} and #{Error.type_name(r)} cannot be added"})
  end

  defp jq_arith(:sub, l, r) when is_number(l) and is_number(r), do: l - r

  defp jq_arith(:sub, l, r) when is_list(l) and is_list(r) do
    Enum.reject(l, fn x -> x in r end)
  end

  defp jq_arith(:sub, l, r) do
    throw({:jq_error, "#{Error.type_name(l)} and #{Error.type_name(r)} cannot be subtracted"})
  end

  defp jq_arith(:mul, l, r) when is_number(l) and is_number(r), do: l * r

  defp jq_arith(:mul, l, r) when is_map(l) and is_map(r) do
    deep_merge(l, r)
  end

  defp jq_arith(:mul, l, r) when is_binary(l) and is_map(r), do: jq_arith(:mul, r, l)

  defp jq_arith(:mul, l, r) do
    throw({:jq_error, "#{Error.type_name(l)} and #{Error.type_name(r)} cannot be multiplied"})
  end

  defp jq_arith(:div, _l, 0), do: throw({:jq_error, "division by zero"})
  defp jq_arith(:div, _l, 0.0), do: throw({:jq_error, "division by zero"})
  defp jq_arith(:div, l, r) when is_number(l) and is_number(r), do: l / r

  defp jq_arith(:div, l, r) when is_binary(l) and is_binary(r) do
    String.split(l, r)
  end

  defp jq_arith(:div, l, r) do
    throw({:jq_error, "#{Error.type_name(l)} and #{Error.type_name(r)} cannot be divided"})
  end

  defp jq_arith(:mod, _l, 0), do: throw({:jq_error, "modulo by zero"})
  defp jq_arith(:mod, l, r) when is_integer(l) and is_integer(r), do: rem(l, r)

  defp jq_arith(:mod, l, r) when is_number(l) and is_number(r) do
    rem(trunc(l), trunc(r))
  end

  defp jq_arith(:mod, l, r) do
    throw({:jq_error, "#{Error.type_name(l)} and #{Error.type_name(r)} cannot use modulo"})
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

  # ── Negate ────────────────────────────────────────────────────────────

  defp do_eval(%Negate{expr: expr}, input, env) do
    for v <- do_eval(expr, input, env) do
      case v do
        n when is_number(n) -> -n
        _ -> throw({:jq_error, "cannot negate #{Error.type_name(v)}"})
      end
    end
  end

  # ── Logical ───────────────────────────────────────────────────────────

  defp do_eval(%LogicalAnd{left: l, right: r}, input, env) do
    for lv <- do_eval(l, input, env),
        rv <- do_eval(r, input, env) do
      jq_truthy?(lv) and jq_truthy?(rv)
    end
  end

  defp do_eval(%LogicalOr{left: l, right: r}, input, env) do
    for lv <- do_eval(l, input, env),
        rv <- do_eval(r, input, env) do
      jq_truthy?(lv) or jq_truthy?(rv)
    end
  end

  defp do_eval(%LogicalNot{expr: e}, input, env) do
    for v <- do_eval(e, input, env), do: not jq_truthy?(v)
  end

  # ── String Interpolation ──────────────────────────────────────────────

  defp do_eval(%StringInterpolation{parts: parts}, input, env) do
    build_interpolation(parts, input, env, [""])
  end

  defp build_interpolation([], _input, _env, acc), do: acc

  defp build_interpolation([{:literal, s} | rest], input, env, acc) do
    build_interpolation(rest, input, env, Enum.map(acc, &(&1 <> s)))
  end

  defp build_interpolation([{:interp, filter} | rest], input, env, acc) do
    values = do_eval(filter, input, env)

    new_acc =
      for prefix <- acc, v <- values do
        prefix <> jq_tostring(v)
      end

    build_interpolation(rest, input, env, new_acc)
  end

  # ── If-Then-Else ──────────────────────────────────────────────────────

  defp do_eval(%IfThenElse{condition: cond_expr, then_branch: then_b, elifs: elifs, else_branch: else_b}, input, env) do
    Enum.flat_map(do_eval(cond_expr, input, env), fn cv ->
      if jq_truthy?(cv) do
        do_eval(then_b, input, env)
      else
        eval_elifs(elifs, else_b, input, env)
      end
    end)
  end

  defp eval_elifs([], nil, input, env), do: do_eval(%Identity{}, input, env)
  defp eval_elifs([], else_b, input, env), do: do_eval(else_b, input, env)

  defp eval_elifs([{cond_expr, body} | rest], else_b, input, env) do
    Enum.flat_map(do_eval(cond_expr, input, env), fn cv ->
      if jq_truthy?(cv), do: do_eval(body, input, env), else: eval_elifs(rest, else_b, input, env)
    end)
  end

  # ── Try-Catch ─────────────────────────────────────────────────────────

  defp do_eval(%TryCatch{try_expr: te, catch_expr: ce}, input, env) do
    try do
      do_eval(te, input, env)
    catch
      {:jq_error, msg} ->
        case ce do
          nil -> []
          expr -> do_eval(expr, msg, env)
        end
    end
  end

  # ── Reduce ────────────────────────────────────────────────────────────

  defp do_eval(%Reduce{expr: expr, var: var, init: init, update: update}, input, env) do
    values = do_eval(expr, input, env)

    init_val =
      case do_eval(init, input, env) do
        [v | _] -> v
        [] -> nil
      end

    result =
      Enum.reduce(values, init_val, fn v, acc ->
        new_env = %{env | bindings: Map.put(env.bindings, var, v)}

        case do_eval(update, acc, new_env) do
          [r | _] -> r
          [] -> acc
        end
      end)

    [result]
  end

  # ── Foreach ───────────────────────────────────────────────────────────

  defp do_eval(%Foreach{expr: expr, var: var, init: init_expr, update: update, extract: extract}, input, env) do
    values = do_eval(expr, input, env)

    init_val =
      case do_eval(init_expr, input, env) do
        [v | _] -> v
        [] -> nil
      end

    {_acc, results} =
      Enum.reduce(values, {init_val, []}, fn v, {acc, outs} ->
        new_env = %{env | bindings: Map.put(env.bindings, var, v)}

        new_acc =
          case do_eval(update, acc, new_env) do
            [r | _] -> r
            [] -> acc
          end

        extracted =
          case extract do
            nil -> [new_acc]
            ext -> do_eval(ext, new_acc, new_env)
          end

        {new_acc, outs ++ extracted}
      end)

    results
  end

  # ── Function Definition ───────────────────────────────────────────────

  defp do_eval(%FuncDef{name: name, params: params, body: body, next: next}, input, env) do
    arity = length(params)
    func_def = %{params: params, body: body, env: env}
    new_env = %{env | functions: Map.put(env.functions, {name, arity}, func_def)}
    do_eval(next, input, new_env)
  end

  # ── Function Call ─────────────────────────────────────────────────────

  defp do_eval(%FuncCall{name: name, args: args}, input, env) do
    arity = length(args)

    case Map.get(env.functions, {name, arity}) do
      %{params: params, body: body, env: closure_env} ->
        arg_fns =
          Enum.zip(params, args)
          |> Map.new(fn {param, arg_filter} ->
            {{param, 0}, %{params: [], body: arg_filter, env: env}}
          end)

        call_env = %{closure_env | functions: Map.merge(closure_env.functions, arg_fns)}
        do_eval(body, input, call_env)

      nil ->
        JQ.Builtins.call(name, args, input, env, &do_eval/3)
    end
  end

  # ── Variable ──────────────────────────────────────────────────────────

  defp do_eval(%Variable{name: name}, _input, env) do
    case Map.fetch(env.bindings, name) do
      {:ok, v} -> [v]
      :error -> throw({:jq_error, "$#{name} is not defined"})
    end
  end

  # ── Binding ───────────────────────────────────────────────────────────

  defp do_eval(%Binding{expr: expr, var: var, body: body}, input, env) do
    Enum.flat_map(do_eval(expr, input, env), fn v ->
      new_env = %{env | bindings: Map.put(env.bindings, var, v)}
      do_eval(body, input, new_env)
    end)
  end

  # ── Pattern Binding ───────────────────────────────────────────────────

  defp do_eval(%PatternBinding{expr: expr, patterns: patterns, body: body}, input, env) do
    Enum.flat_map(do_eval(expr, input, env), fn v ->
      new_bindings = extract_pattern_bindings(patterns, v, env.bindings)
      new_env = %{env | bindings: new_bindings}
      do_eval(body, input, new_env)
    end)
  end

  defp extract_pattern_bindings(patterns, value, bindings) when is_list(patterns) do
    Enum.reduce(patterns, bindings, fn
      {name, var_name}, acc when is_binary(name) and is_binary(var_name) ->
        Map.put(acc, var_name, Map.get(value, name, nil))

      _, acc ->
        acc
    end)
  end

  # ── Label / Break ────────────────────────────────────────────────────

  defp do_eval(%Label{name: name, body: body}, input, env) do
    try do
      do_eval(body, input, env)
    catch
      {:jq_break, ^name, value} -> [value]
      {:jq_break, ^name} -> []
    end
  end

  defp do_eval(%Break{name: name}, _input, _env) do
    throw({:jq_break, name})
  end

  # ── Optional ──────────────────────────────────────────────────────────

  defp do_eval(%Optional{expr: expr}, input, env) do
    try do
      do_eval(expr, input, env)
    catch
      {:jq_error, _} -> []
    end
  end

  # ── Assign ────────────────────────────────────────────────────────────

  defp do_eval(%Assign{path: path, op: :update, value: filter}, input, env) do
    [update_path(input, path, filter, env)]
  end

  defp do_eval(%Assign{path: path, op: :assign, value: val_expr}, input, env) do
    for v <- do_eval(val_expr, input, env) do
      set_path_value(input, path, v, env)
    end
  end

  defp do_eval(%Assign{path: path, op: op, value: val_expr}, input, env) do
    arith_op =
      case op do
        :add -> :add
        :sub -> :sub
        :mul -> :mul
        :div -> :div
        :mod -> :mod
        :alt -> :alt
      end

    combined = %Arithmetic{op: arith_op, left: %Identity{}, right: val_expr}
    [update_path(input, path, combined, env)]
  end

  defp update_path(input, %Field{name: name}, filter, env) when is_map(input) do
    old = Map.get(input, name)

    case do_eval(filter, old, env) do
      [new_val | _] -> Map.put(input, name, new_val)
      [] -> input
    end
  end

  defp update_path(input, %Iterate{}, filter, env) when is_list(input) do
    Enum.map(input, fn elem ->
      case do_eval(filter, elem, env) do
        [v | _] -> v
        [] -> elem
      end
    end)
  end

  defp update_path(input, %Iterate{}, filter, env) when is_map(input) do
    Map.new(input, fn {k, v} ->
      case do_eval(filter, v, env) do
        [new_v | _] -> {k, new_v}
        [] -> {k, v}
      end
    end)
  end

  defp update_path(input, %Pipe{left: left, right: right}, filter, env) do
    update_path(input, left, %Assign{path: right, op: :update, value: filter}, env)
  end

  defp update_path(input, _path, _filter, _env), do: input

  defp set_path_value(input, %Field{name: name}, value, _env) when is_map(input) do
    Map.put(input, name, value)
  end

  defp set_path_value(nil, %Field{name: name}, value, _env) do
    %{name => value}
  end

  defp set_path_value(input, %Index{expr: idx_expr}, value, env) when is_list(input) do
    case do_eval(idx_expr, input, env) do
      [idx | _] when is_integer(idx) ->
        idx = if idx < 0, do: length(input) + idx, else: idx
        List.replace_at(input, idx, value)

      _ ->
        input
    end
  end

  defp set_path_value(input, %Pipe{left: left, right: right}, value, env) do
    update_path(input, left, %Assign{path: right, op: :assign, value: %Literal{value: value}}, env)
  end

  defp set_path_value(input, _path, _value, _env), do: input

  # ── Format ────────────────────────────────────────────────────────────

  defp do_eval(%Format{name: name, expr: nil}, input, env) do
    do_eval(%Format{name: name, expr: %Identity{}}, input, env)
  end

  defp do_eval(%Format{name: name, expr: expr}, input, env) do
    for v <- do_eval(expr, input, env) do
      apply_format(name, v)
    end
  end

  defp apply_format("text", v), do: jq_tostring(v)
  defp apply_format("json", v), do: JSON.encode!(v)
  defp apply_format("html", v), do: html_escape(jq_tostring(v))
  defp apply_format("uri", v), do: URI.encode(jq_tostring(v))
  defp apply_format("csv", v) when is_list(v), do: format_csv(v)
  defp apply_format("tsv", v) when is_list(v), do: format_tsv(v)
  defp apply_format("base64", v), do: Base.encode64(jq_tostring(v))
  defp apply_format("base64d", v), do: Base.decode64!(jq_tostring(v))
  defp apply_format("base32", v), do: Base.encode32(jq_tostring(v))
  defp apply_format("base32d", v), do: Base.decode32!(jq_tostring(v))
  defp apply_format(name, _v), do: throw({:jq_error, "unknown format: @#{name}"})

  defp html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("'", "&apos;")
    |> String.replace("\"", "&quot;")
  end

  defp format_csv(values) do
    values
    |> Enum.map_join(",", fn
      v when is_binary(v) ->
        if String.contains?(v, [",", "\"", "\n"]) do
          "\"" <> String.replace(v, "\"", "\"\"") <> "\""
        else
          v
        end

      v ->
        jq_tostring(v)
    end)
  end

  defp format_tsv(values) do
    values
    |> Enum.map_join("\t", fn v ->
      jq_tostring(v)
      |> String.replace("\\", "\\\\")
      |> String.replace("\t", "\\t")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
    end)
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  @doc false
  def jq_truthy?(false), do: false
  def jq_truthy?(nil), do: false
  def jq_truthy?(_), do: true

  @doc false
  def jq_tostring(v) when is_binary(v), do: v
  def jq_tostring(nil), do: "null"
  def jq_tostring(true), do: "true"
  def jq_tostring(false), do: "false"
  def jq_tostring(v) when is_integer(v), do: Integer.to_string(v)
  def jq_tostring(v) when is_float(v) do
    if v == Float.floor(v) and abs(v) < 1.0e18, do: v |> trunc() |> Integer.to_string(), else: :erlang.float_to_binary(v, [:short])
  end

  def jq_tostring(v), do: JSON.encode!(v)

  defp type_order(nil), do: 0
  defp type_order(false), do: 1
  defp type_order(true), do: 2
  defp type_order(n) when is_number(n), do: 3
  defp type_order(s) when is_binary(s), do: 4
  defp type_order(l) when is_list(l), do: 5
  defp type_order(m) when is_map(m), do: 6
  defp type_order(_), do: 7

  @doc false
  def jq_compare(a, b) do
    ta = type_order(a)
    tb = type_order(b)

    cond do
      ta < tb -> :lt
      ta > tb -> :gt
      true -> compare_same_type(a, b)
    end
  end

  defp compare_same_type(nil, nil), do: :eq
  defp compare_same_type(a, b) when is_boolean(a) and is_boolean(b), do: if(a == b, do: :eq, else: if(b, do: :lt, else: :gt))
  defp compare_same_type(a, b) when is_number(a) and is_number(b), do: cond do a < b -> :lt; a > b -> :gt; true -> :eq end
  defp compare_same_type(a, b) when is_binary(a) and is_binary(b), do: cond do a < b -> :lt; a > b -> :gt; true -> :eq end

  defp compare_same_type(a, b) when is_list(a) and is_list(b) do
    compare_lists(a, b)
  end

  defp compare_same_type(a, b) when is_map(a) and is_map(b) do
    ka = Enum.sort(Map.keys(a))
    kb = Enum.sort(Map.keys(b))

    case compare_lists(ka, kb) do
      :eq ->
        va = Enum.map(ka, &Map.get(a, &1))
        vb = Enum.map(ka, &Map.get(b, &1))
        compare_lists(va, vb)

      other ->
        other
    end
  end

  defp compare_same_type(_, _), do: :eq

  defp compare_lists([], []), do: :eq
  defp compare_lists([], _), do: :lt
  defp compare_lists(_, []), do: :gt

  defp compare_lists([ah | at], [bh | bt]) do
    case jq_compare(ah, bh) do
      :eq -> compare_lists(at, bt)
      other -> other
    end
  end
end
