defmodule Scry.Engine.Ch.Conn do
  @moduledoc """
  Wraps a `ch` connection pid -- opened once via `open/1` and meant to
  be reused across many `Scry.Engine.Ch.execute/3` calls, matching the
  connection/config struct every real adapter exposes (impl_spec.md
  §2). Unlike `Scry.Engine.Exqlite.Conn`/`Scry.Engine.Duckdbex.Conn`
  (a raw native handle, no process involved), `ch` is `DBConnection`-
  based -- `Ch.start_link/1` always starts a real, linked pool process
  (default `pool_size: 1`), never a bare handle. `open/1` calls it
  unsupervised, the same posture an ad hoc `Ecto.Repo.start_link/1`
  call outside a supervision tree has -- an application wanting this
  connection properly supervised should add `{Ch, opts}`'s own
  `child_spec` to its own supervision tree directly instead of calling
  `open/1`, the same way it would for any other `DBConnection`-based
  dependency.
  """

  @type t :: %__MODULE__{pid: pid()}

  defstruct pid: nil

  @doc """
  Starts a `ch` connection pool against `opts` (`Ch.start_link/1`'s
  own options -- `scheme`/`hostname`/`port`/`database`/`username`/
  `password`/... -- defaulting to `scheme: "http", hostname:
  "localhost", port: 8123, database: "default"`, a stock local
  `clickhouse-server` container with `CLICKHOUSE_SKIP_USER_SETUP=1`).
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    with {:ok, pid} <- Ch.start_link(opts) do
      {:ok, %__MODULE__{pid: pid}}
    end
  end

  @doc "Stops the wrapped connection pool."
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}), do: GenServer.stop(pid)
end
