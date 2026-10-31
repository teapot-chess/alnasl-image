defmodule AlnaslSetup.Lock do
  @moduledoc """
  The setup server's one lock (Python's threading.RLock): every POST and every timer that changes the
  box (revert a network setting, undo a resolution) runs under it, one at a time. Re-entrant for the
  process that holds it. `:global.trans` works on a node that is not distributed, too.
  """

  def with_lock(fun) when is_function(fun, 0) do
    :global.trans({__MODULE__, self()}, fun, [node()], :infinity)
  end
end
