defmodule Bash.Builtin.ExecTest do
  use Bash.SessionCase, async: true
  setup :start_session

  alias Bash.Session

  describe "exec" do
    test "with no command is a no-op", %{session: session} do
      result =
        run_script(session, ~S"""
        exec; echo still_here
        """)

      assert result.exit_code == 0
      assert get_stdout(result) == "still_here\n"
    end

    test "with a command stops script execution", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("exec true; echo unreachable")

      case Session.execute(session, ast) do
        {:exec, result} ->
          assert get_stdout(result) == ""

        other ->
          flunk("Expected {:exec, _}, got: #{inspect(other)}")
      end
    end

    test "-c flag clears the environment", %{session: session} do
      run_script(session, "export MY_VAR=hello")

      {:ok, ast} = Bash.Parser.parse("exec -c env")

      case Session.execute(session, ast) do
        {:exec, result} ->
          refute get_stdout(result) =~ "MY_VAR=hello"

        other ->
          flunk("Expected {:exec, _}, got: #{inspect(other)}")
      end
    end

    test "-l flag produces exec result", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("exec -l true")

      case Session.execute(session, ast) do
        {:exec, _result} ->
          assert true

        other ->
          flunk("Expected {:exec, _}, got: #{inspect(other)}")
      end
    end

    test "-a name flag produces exec result", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("exec -a custom_name true")

      case Session.execute(session, ast) do
        {:exec, _result} ->
          assert true

        other ->
          flunk("Expected {:exec, _}, got: #{inspect(other)}")
      end
    end

    test "invalid option returns exit code 2", %{session: session} do
      result = run_script(session, "exec -z 2>/dev/null; echo $?")
      assert get_stdout(result) =~ "2"
    end

    test "-a without argument returns error", %{session: session} do
      result = run_script(session, "exec -a 2>/dev/null; echo $?")
      assert get_stdout(result) =~ "2"
    end

    test "combined flags -cl produce exec result", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("exec -cl true")

      case Session.execute(session, ast) do
        {:exec, _result} ->
          assert true

        other ->
          flunk("Expected {:exec, _}, got: #{inspect(other)}")
      end
    end

    test "-- ends option parsing", %{session: session} do
      {:ok, ast} = Bash.Parser.parse("exec -- true")

      case Session.execute(session, ast) do
        {:exec, _result} ->
          assert true

        other ->
          flunk("Expected {:exec, _}, got: #{inspect(other)}")
      end
    end
  end

  describe "exec FD redirect" do
    test "exec 3>&1 then echo >&3 writes to stdout", %{session: session} do
      result =
        run_script(session, ~S"""
        exec 3>&1
        echo "to fd 3" >&3
        exec 3>&-
        """)

      assert get_stdout(result) |> String.trim() == "to fd 3"
    end

    test "exec 4>&1 then echo >&4 writes to stdout", %{session: session} do
      result =
        run_script(session, ~S"""
        exec 4>&1
        echo "to fd 4" >&4
        exec 4>&-
        """)

      assert get_stdout(result) |> String.trim() == "to fd 4"
    end
  end
end
