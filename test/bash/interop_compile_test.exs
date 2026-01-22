defmodule Bash.InteropOnDefineTest do
  use ExUnit.Case, async: true

  defmodule BasicAPI do
    use Bash.Interop, namespace: "basic"

    defbash(hello(_args, _state), do: {:ok, "hello"})
  end

  defmodule AnnotatedAPI do
    use Bash.Interop,
      namespace: "annotated",
      on_define: fn _name, module ->
        # Callback can read module attributes set before defbash
        execute_on = Module.get_attribute(module, :execute_on) || :guest
        Module.delete_attribute(module, :execute_on)
        %{execute_on: execute_on}
      end

    defbash(default_mode(_args, _state), do: {:ok, "default"})

    @execute_on :server
    defbash(server_mode(_args, _state), do: {:ok, "server"})

    @execute_on :guest
    defbash(explicit_guest(_args, _state), do: {:ok, "guest"})
  end

  defmodule ExplicitNilAPI do
    use Bash.Interop,
      namespace: "explicit_nil",
      on_define: fn name, _module ->
        if name == "skip_meta", do: nil, else: %{tracked: true}
      end

    defbash(skip_meta(_args, _state), do: {:ok, "skipped"})
    defbash(tracked(_args, _state), do: {:ok, "tracked"})
  end

  describe "__bash_function_meta__/1 with on_define callback" do
    test "returns nil when no on_define callback" do
      assert BasicAPI.__bash_function_meta__("hello") == nil
    end

    test "returns metadata from on_define callback" do
      assert AnnotatedAPI.__bash_function_meta__("default_mode") == %{execute_on: :guest}
    end

    test "callback can read module attributes" do
      assert AnnotatedAPI.__bash_function_meta__("server_mode") == %{execute_on: :server}
    end

    test "returns nil for unknown function" do
      assert AnnotatedAPI.__bash_function_meta__("unknown") == nil
    end

    test "callback returning nil stores no metadata" do
      assert ExplicitNilAPI.__bash_function_meta__("skip_meta") == nil
      assert ExplicitNilAPI.__bash_function_meta__("tracked") == %{tracked: true}
    end
  end

  describe "__bash_functions__/0 with on_define callback" do
    test "lists all defined functions" do
      assert "hello" in BasicAPI.__bash_functions__()
      assert "default_mode" in AnnotatedAPI.__bash_functions__()
      assert "server_mode" in AnnotatedAPI.__bash_functions__()
    end
  end
end
