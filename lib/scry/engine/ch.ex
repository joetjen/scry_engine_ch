defmodule Scry.Engine.Ch do
  @moduledoc """
  A real, kind-independent `Scry.Core.EngineBehaviour` implementation
  over [ClickHouse](https://clickhouse.com/), via the
  [`ch`](https://hex.pm/packages/ch) driver. `execute/3` compiles the
  *entire* flat query -- `WHERE`/`GROUP BY`/aggregates/`ORDER BY`/
  `DISTINCT`/`LIMIT`/`OFFSET`/projection -- into one native SQL
  statement via `Scry.Engine.Ch.SqlCompiler`, all or nothing, the same
  posture `scry_engine_exqlite`/`scry_engine_duckdbex` already
  established. Closes the validation lang_spec.md §12 already commits
  to (the time-series kind, framed around "the RabbitMQ/ClickHouse use
  case") -- none of the engines built before this one (in-memory, ETS,
  SQLite, PostgreSQL, DuckDB) exercise a genuine time-series-oriented
  product; `scry_time_series`'s own `LAST`-lowering pass already
  rewrites into an ordinary `WHERE` predicate before any engine ever
  sees it (`scry_engine_postgrex`'s own TimescaleDB validation found
  the identical "zero new code needed" result), so this package needs
  no time-series-specific code of its own to close that gap -- being a
  correct, general `Scry.Core.EngineBehaviour` implementation already
  does.

  **What's genuinely different from this package's SQL-engine
  siblings, confirmed directly against a real ClickHouse server rather
  than assumed from either one's own precedent:**

  - `ch` is `DBConnection`-based (a real, linked pool process via
    `Ch.start_link/1`), not a bare native handle the way `exqlite`/
    `duckdbex` both are -- `Scry.Engine.Ch.Conn`'s own moduledoc has
    the full reasoning.
  - ClickHouse has **no untyped bind placeholder at all** -- every
    parameter's own ClickHouse type has to be spelled out inline in
    the SQL text (`{$0:Int64}`, `{$1:String}`, ...), zero-based,
    confirmed directly (unlike `scry_engine_duckdbex`'s one-based,
    untyped `$1`). `Scry.Engine.Ch.WhereTranslator` picks the type
    annotation per Elixir value's own class (`String`/`Int64`/
    `Float64`/`DateTime64(6)`), not per the target column's real
    declared type, relying on ClickHouse's own confirmed-correct
    cross-width numeric widening rather than needing to introspect
    the column first.
  - **Booleans are declined**, unlike `scry_engine_duckdbex`'s own --
    a real, confirmed ClickHouse-specific silent-wrong-result risk
    (`Bool`/integer numeric coercion), not the "no native type at all"
    reason SQLite's own translator declines them for. `Scry.Engine.Ch.
    WhereTranslator`'s own moduledoc has the full account.
  - **Nullability is inverted**: a column is `NOT NULL` by default;
    only an explicit `Nullable(...)` type wrapper opts in to allowing
    `NULL` at all. `Scry.Engine.Ch.Schema`'s own moduledoc has the
    full account, including why an unknown table's own schema query
    needs no special error handling here (a real, confirmed difference
    from `scry_engine_duckdbex`'s own `PRAGMA table_info`, which
    raises a `Catalog Error` for the identical case).
  - **The `NOT NULL` check runs immediately before the compiled query,
    not inside a shared transaction with it** -- ClickHouse has no
    standard multi-statement transaction concept over its HTTP
    interface at all, confirmed directly (neither the server nor `ch`
    itself expose one), so the atomic "check and query can't be torn
    apart by a concurrent schema change" guarantee `scry_engine_exqlite`/
    `scry_engine_duckdbex` both offer isn't structurally available
    here. A real, honestly-stated gap, not a papered-over one.
  - **Always eager, never a lazy `Stream`** -- `ch`'s own `Ch.query/3`
    returns one fully-materialized `%Ch.Result{}` per call (there is
    no separate chunked-fetch API this package found and validated the
    way `duckdbex`'s own `fetch_chunk/1` is), so unlike its SQL-engine
    siblings, `execute/3` never returns a `Stream`-backed enumerable
    for the direct pushdown path -- a stated scope choice, not a bug,
    given nothing in this package's own research or empirical
    validation found a genuine streaming primitive to build one on.

  **A `SELECT` with no `ORDER BY` has no guaranteed row order at all**
  -- found running this package's own test suite, not assumed:
  `MergeTree` (ClickHouse's own standard table engine) returns rows in
  whatever physical/merge order the storage layer happens to hold them
  in, not insertion order, unlike the embedded SQLite/DuckDB siblings'
  own (incidental, never guaranteed there either, but empirically
  stable enough not to bite) small-table scan behavior. Any query
  whose own row order matters -- including a correlated nested
  `SELECT` body item -- needs an explicit `order_bys` of its own; this
  package adds no implicit one.

  Table (and column) names are validated against a plain SQL-identifier
  pattern before ever being interpolated into a SQL string -- every
  *value* is always bound via a real, typed `{$N:Type}` placeholder,
  never string-interpolated. Index creation, schema, and connection
  lifecycle are deliberately not this module's job.
  """

  @behaviour Scry.Core.EngineBehaviour

  alias Scry.Core.{CombinedQuery, EngineBehaviour, Query, QueryOps, Row}
  alias Scry.Engine.Ch.{Conn, Schema, SqlCompiler}

  @impl true
  def execute(conn, %CombinedQuery{} = combined, params),
    do: QueryOps.run_document(conn, combined, params, __MODULE__)

  def execute(%Conn{} = conn, %Query{source: source} = query, params) do
    if Enum.any?(query.select, &match?(%Query{}, &1)) or with_bound_source?(query) do
      QueryOps.run_document(conn, query, params, __MODULE__)
    else
      case SqlCompiler.compile(query, params) do
        {:ok, %{not_null_columns: []} = compiled} ->
          run_sql(conn, compiled)

        {:ok, compiled} ->
          [table] = source

          with :ok <- Schema.verify(conn, table, compiled.not_null_columns) do
            run_sql(conn, compiled)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp with_bound_source?(%Query{source: [name], with_bindings: with_bindings}),
    do: Map.has_key?(with_bindings, name)

  defp with_bound_source?(_query), do: false

  defp run_sql(%Conn{pid: pid}, %{sql: sql, bind_params: bind_params}) do
    case Ch.query(pid, sql, bind_params) do
      {:ok, result} ->
        index = Row.build_index(result.columns)
        {:ok, Enum.map(result.rows, &Row.new(index, &1))}

      {:error, reason} ->
        {:error, {:query_error, reason}}
    end
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback
  -- delegates straight to `Scry.Engine.Ch.Schema.describe_source/2`.
  """
  @impl true
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(conn, source), do: Schema.describe_source(conn, source)
end
