defmodule Bash.Variable do
  @moduledoc """
  Bash variable with attributes and value.
  Supports scalar values, indexed arrays, and associative arrays.

  ## Working with Sessions

  You can retrieve variables directly from a session:

      Variable.get(session, "myvar")           # Get scalar variable
      Variable.get(session, "myarray", 0)      # Get array element at index 0
      Variable.get(session, "myassoc", "key")  # Get associative array element

  Or work with Variable structs directly:

      var = Variable.new("hello")
      Variable.get(var, nil)  # => "hello"
  """

  alias Bash.Session

  @type array_type :: :indexed | :associative | nil
  @type attributes :: %{
          readonly: boolean(),
          export: boolean(),
          integer: boolean(),
          array_type: array_type(),
          nameref: String.t() | nil
        }
  @type value :: String.t() | %{integer() => String.t()} | %{String.t() => String.t()}

  @type t :: %__MODULE__{
          value: value(),
          attributes: attributes()
        }

  defstruct value: "",
            attributes: %{
              readonly: false,
              export: false,
              integer: false,
              lowercase: false,
              uppercase: false,
              array_type: nil,
              nameref: nil
            }

  @doc "Create scalar variable"
  def new(value \\ ""), do: %__MODULE__{value: value}

  @doc "Create indexed array"
  def new_indexed_array(values \\ %{}) do
    %__MODULE__{
      value: values,
      attributes: %{
        readonly: false,
        export: false,
        integer: false,
        lowercase: false,
        uppercase: false,
        array_type: :indexed
      }
    }
  end

  @doc "Create associative array"
  def new_associative_array(values \\ %{}) do
    %__MODULE__{
      value: values,
      attributes: %{
        readonly: false,
        export: false,
        integer: false,
        lowercase: false,
        uppercase: false,
        array_type: :associative
      }
    }
  end

  @doc "Create a nameref variable that references another variable by name"
  def new_nameref(target_name) when is_binary(target_name) do
    %__MODULE__{
      value: target_name,
      attributes: %{
        readonly: false,
        export: false,
        integer: false,
        lowercase: false,
        uppercase: false,
        array_type: nil,
        nameref: target_name
      }
    }
  end

  @doc "Returns true if the variable is marked readonly."
  def readonly?(%__MODULE__{attributes: %{readonly: true}}), do: true
  def readonly?(_), do: false

  @doc "Returns true if the variable is a nameref."
  def nameref?(%__MODULE__{attributes: %{nameref: ref}}) when is_binary(ref), do: true
  def nameref?(_), do: false

  @doc "Get the nameref target variable name, or nil if not a nameref."
  def nameref_target(%__MODULE__{attributes: %{nameref: ref}}) when is_binary(ref), do: ref
  def nameref_target(_), do: nil

  @doc "Returns true if the variable is an array (indexed or associative)."
  def array?(%__MODULE__{attributes: %{array_type: type}}) when not is_nil(type), do: true
  def array?(_), do: false

  @doc "Returns true if the variable is an associative array."
  def is_associative_array?(%__MODULE__{attributes: %{array_type: :associative}}), do: true
  def is_associative_array?(_), do: false

  @doc """
  Get variable value from a session or a Variable struct.

  ## Session-based access

  If the first parameter is a PID or Session struct, retrieves the session state
  and looks up the variable by name.

      Variable.get(session, "myvar")
      Variable.get(session_pid, "HOME")

  With optional array index or key:

      Variable.get(session, "myarray", 0)      # Get first element
      Variable.get(session, "myassoc", "key")  # Get value for "key"

  ## Variable struct access

  If the first parameter is a Variable struct, returns the value at the given
  index (for arrays) or the full value (for scalars).

      Variable.get(var, nil)   # Get scalar value
      Variable.get(var, 0)     # Get array element at index 0
      Variable.get(var, "key") # Get associative array value

  """
  # Session-based get/2
  def get(%Session{} = session, var_name) when is_binary(var_name) do
    get(session, var_name, nil)
  end

  def get(session, var_name) when is_pid(session) and is_binary(var_name) do
    get(session, var_name, nil)
  end

  # Plain map with :variables key (for tests)
  def get(%{variables: vars} = state, var_name)
      when is_binary(var_name) and is_map(vars) do
    get(state, var_name, nil)
  end

  # Variable struct-based get/2
  def get(%__MODULE__{attributes: %{array_type: nil}, value: v}, nil), do: v
  # arr[0] on scalar returns the scalar
  def get(%__MODULE__{attributes: %{array_type: nil}, value: v}, 0), do: v

  def get(%__MODULE__{attributes: %{array_type: :indexed}, value: map}, idx)
      when is_integer(idx) and idx >= 0,
      do: Map.get(map, idx, "")

  def get(%__MODULE__{attributes: %{array_type: :indexed}, value: map}, idx)
      when is_integer(idx) and idx < 0 do
    max_idx = map |> Map.keys() |> Enum.max(fn -> -1 end)
    resolved = max_idx + 1 + idx
    if resolved >= 0, do: Map.get(map, resolved, ""), else: ""
  end

  def get(%__MODULE__{attributes: %{array_type: :associative}, value: map}, key)
      when is_binary(key),
      do: Map.get(map, key, "")

  def get(_, _), do: ""

  # Session-based get/3
  def get(%Session{variables: vars}, var_name, index_or_key) when is_binary(var_name) do
    case Map.get(vars, var_name) do
      nil -> ""
      %__MODULE__{} = var -> get(var, index_or_key)
    end
  end

  # Plain map with :variables key (for tests)
  def get(%{variables: vars}, var_name, index_or_key)
      when is_binary(var_name) and is_map(vars) do
    case Map.get(vars, var_name) do
      nil -> ""
      %__MODULE__{} = var -> get(var, index_or_key)
    end
  end

  def get(session, var_name, index_or_key) when is_pid(session) and is_binary(var_name) do
    state = Session.get_state(session)
    get(state, var_name, index_or_key)
  end

  @doc "Get all values for ${arr[@]} expansion"
  def all_values(%__MODULE__{attributes: %{array_type: nil}, value: v}), do: [v]

  def all_values(%__MODULE__{attributes: %{array_type: :indexed}, value: map}),
    do: map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  def all_values(%__MODULE__{value: map}) when is_map(map), do: Map.values(map)

  @doc "Get all keys for ${!arr[@]} expansion"
  def all_keys(%__MODULE__{attributes: %{array_type: :indexed}, value: map}),
    do: map |> Map.keys() |> Enum.sort() |> Enum.map(&to_string/1)

  def all_keys(%__MODULE__{attributes: %{array_type: :associative}, value: map}),
    do: Map.keys(map)

  def all_keys(_), do: []

  @doc "Get length for ${#arr[@]} or ${#var}"
  def length(%__MODULE__{attributes: %{array_type: nil}, value: v}), do: String.length(v)
  def length(%__MODULE__{value: map}) when is_map(map), do: map_size(map)

  @doc "Set value at index, returns new Variable"
  def set(%__MODULE__{attributes: %{array_type: nil}} = var, value, nil),
    do: %{var | value: value}

  def set(%__MODULE__{attributes: %{array_type: type}, value: map} = var, value, idx)
      when not is_nil(type),
      do: %{var | value: Map.put(map, idx, value)}
end
