defmodule Bash.AST.Redirect do
  @moduledoc """
  I/O redirection.

  ## Examples

      # < input.txt
      %Redirect{
        direction: :input,
        fd: 0,
        target: {:file, %Word{parts: [{:literal, "input.txt"}]}}
      }

      # > output.txt
      %Redirect{
        direction: :output,
        fd: 1,
        target: {:file, %Word{parts: [{:literal, "output.txt"}]}}
      }

      # >> append.txt
      %Redirect{
        direction: :append,
        fd: 1,
        target: {:file, %Word{parts: [{:literal, "append.txt"}]}}
      }

      # 2>&1 (redirect stderr to stdout)
      %Redirect{
        direction: :duplicate,
        fd: 2,
        target: {:fd, 1}
      }

      # &> all_output.txt (redirect both stdout and stderr)
      %Redirect{
        direction: :output,
        fd: :both,
        target: {:file, %Word{parts: [{:literal, "all_output.txt"}]}}
      }

      # <<EOF (heredoc)
      # content
      # EOF
      %Redirect{
        direction: :heredoc,
        fd: 0,
        target: {:heredoc, %Word{parts: [{:literal, "content\\n"}]}, "EOF", false}
      }

      # <<< "string" (herestring)
      %Redirect{
        direction: :herestring,
        fd: 0,
        target: {:word, %Word{parts: [{:literal, "string"}]}}
      }
  """

  alias Bash.AST

  @type direction :: :input | :output | :append | :duplicate | :heredoc | :herestring

  @type target ::
          {:file, AST.Word.t()}
          | {:fd, integer()}
          | {:heredoc, content :: AST.Word.t(), delimiter :: String.t(), strip_tabs :: boolean()}
          | {:word, AST.Word.t()}

  @type t :: %__MODULE__{
          meta: AST.Meta.t(),
          direction: direction(),
          fd: integer() | :both | {:var, String.t()},
          target: target()
        }

  defstruct [:meta, :direction, :fd, :target]

  defimpl String.Chars do
    # Combined stdout+stderr - must come first (more specific patterns)
    def to_string(%{direction: :output, fd: :both, target: {:file, file}}) do
      "&> #{file}"
    end

    def to_string(%{direction: :append, fd: :both, target: {:file, file}}) do
      "&>> #{file}"
    end

    # Standard redirects
    def to_string(%{direction: :input, fd: fd, target: {:file, file}}) when is_integer(fd) do
      fd_str = if fd == 0, do: "", else: "#{fd}"
      "#{fd_str}< #{file}"
    end

    def to_string(%{direction: :output, fd: fd, target: {:file, file}}) when is_integer(fd) do
      fd_str = if fd == 1, do: "", else: "#{fd}"
      "#{fd_str}> #{file}"
    end

    def to_string(%{direction: :append, fd: fd, target: {:file, file}}) when is_integer(fd) do
      fd_str = if fd == 1, do: "", else: "#{fd}"
      "#{fd_str}>> #{file}"
    end

    def to_string(%{direction: :duplicate, fd: fd, target: {:fd, target_fd}})
        when is_integer(fd) do
      fd_str = if fd == 1, do: "", else: "#{fd}"
      "#{fd_str}>&#{target_fd}"
    end

    # Heredoc: <<DELIM ... DELIM or <<-DELIM ... DELIM
    def to_string(%{
          direction: :heredoc,
          fd: fd,
          target: {:heredoc, %Bash.AST.Word{} = word, delimiter, strip_tabs}
        }) do
      fd_str = if fd == 0, do: "", else: "#{fd}"
      dash = if strip_tabs, do: "-", else: ""
      content = Kernel.to_string(word)
      content_trimmed = String.trim_trailing(content, "\n")
      "#{fd_str}<<#{dash}#{delimiter}\n#{content_trimmed}\n#{delimiter}"
    end

    # Heredoc pending (not yet processed)
    def to_string(%{
          direction: :heredoc,
          fd: fd,
          target: {:heredoc_pending, delimiter, strip_tabs, _expand}
        }) do
      fd_str = if fd == 0, do: "", else: "#{fd}"
      dash = if strip_tabs, do: "-", else: ""
      "#{fd_str}<<#{dash}#{delimiter}"
    end

    # Herestring: <<< word
    def to_string(%{direction: :herestring, fd: fd, target: {:word, word}}) do
      fd_str = if fd == 0, do: "", else: "#{fd}"
      "#{fd_str}<<< #{word}"
    end
  end

  defimpl Inspect do
    def inspect(%{direction: direction}, _opts) do
      "#Redirect{#{direction}}"
    end
  end
end
