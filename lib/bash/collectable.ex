defimpl Collectable, for: Bash.Script do
  @moduledoc """
  Implements Collectable for AST.Script to allow building scripts from enumerables.

  ## Examples

      # Build a script from a list of commands
      commands = [cmd1, cmd2, cmd3]
      script = Enum.into(commands, %Bash.Script{})

      # Build a script with for comprehension
      script =
        for cmd <- commands, into: %Bash.Script{} do
          cmd
        end

      # Filter and collect
      script =
        statements
        |> Enum.filter(fn
          %Bash.AST.Command{} -> true
          _ -> false
        end)
        |> Enum.into(%Bash.Script{})

      # Build with separators
      script =
        Enum.into([cmd1, {:separator, ";"}, cmd2], %Bash.Script{})
  """

  @doc """
  Collects statements into a script.

  Automatically adds newline separators between statements unless
  separators are explicitly provided.
  """
  def into(original) do
    collector_fun = fn
      script, {:cont, statement} ->
        # Add statement to the script
        new_statements =
          case {statement, script.statements} do
            # Adding a separator - just add it
            {{:separator, _}, _} ->
              script.statements ++ [statement]

            # Adding first statement - no separator needed
            {_, []} ->
              [statement]

            # Adding statement when last item is already a separator - just add the statement
            {_, [_ | _] = statements} ->
              if match?({:separator, _}, List.last(statements)) do
                statements ++ [statement]
              else
                # Last item is not a separator, add one before this statement
                statements ++ [{:separator, "\n"}, statement]
              end
          end

        %{script | statements: new_statements}

      script, :done ->
        script

      _script, :halt ->
        :ok
    end

    {original, collector_fun}
  end
end
