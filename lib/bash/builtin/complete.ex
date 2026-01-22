defmodule Bash.Builtin.Complete do
  @moduledoc """
  `complete [-abcdefgjksuv] [-pr] [-o option] [-A action] [-G globpat] [-W wordlist] [-P prefix] [-S suffix] [-X filterpat] [-F function] [-C command] [name ...]`

  For each NAME, specify how arguments are to be completed.  If the -p option is supplied, or if no options are supplied, existing  completion specifications are printed in a way that allows them to be  reused as input.  The -r option removes a completion specification for  each NAME, or, if no NAMEs are supplied, all completion specifications.

  Reference: https://cgit.git.savannah.gnu.org/cgit/bash.git/plain/builtins/complete.def?h=bash-5.3
  """
end
