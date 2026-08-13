defmodule Scry.Engine.Ch.Schema do
  @moduledoc """
  ClickHouse schema introspection (`system.columns`), extracted out of
  `Scry.Engine.Ch` itself so it can be reused by two independent
  consumers: `Scry.Engine.Ch`'s own per-query `NOT NULL` gate and this
  module's own `describe_source/2` (`Scry.Core.EngineBehaviour`'s
  optional callback).

  **Nullability is inverted from SQLite/DuckDB, confirmed directly
  against a real server**: a ClickHouse column is `NOT NULL` *by
  default* -- there is no `notnull`-style flag to read from schema
  metadata at all. A column only accepts `NULL` when its own declared
  type is explicitly wrapped `Nullable(...)`, so this module answers
  "is this column guaranteed not null" by checking that its own
  `system.columns.type` string does *not* start with `Nullable(` --
  the opposite polarity from `Scry.Engine.Exqlite.Schema`/`Scry.Engine.
  Duckdbex.Schema`'s own `notnull` flag check.

  **A query against `system.columns` for an unknown table returns an
  empty result set, not an error** -- confirmed directly, unlike
  `scry_engine_duckdbex`'s own `PRAGMA table_info` (a real ClickHouse
  `Catalog Error` there). This module's own `verify/3`/`describe_source/2`
  therefore need no special "was this actually an error, or just an
  unknown table" handling at all -- the same simple "empty means
  proceed"/"empty means not found" shape `scry_engine_exqlite`'s own
  Schema module already uses for SQLite's identically-shaped case.

  No per-`Conn` cache, matching `scry_engine_duckdbex`'s own choice
  (no cheap, monotonic "has anything changed" signal to invalidate
  against, and no measured cost yet motivating one).
  """

  alias Scry.Core.EngineBehaviour
  alias Scry.Engine.Ch.Conn

  @doc """
  Fetches `table`'s own `name, type` pairs from `system.columns`
  against `conn`'s current database, in declared column order. `[]`
  for an unknown table (see this module's own moduledoc).
  """
  @spec columns(Conn.t(), String.t()) :: {:ok, [[String.t()]]} | {:error, term()}
  def columns(%Conn{pid: pid}, table) do
    sql =
      "SELECT name, type FROM system.columns WHERE table = {$0:String} AND database = currentDatabase() ORDER BY position"

    case Ch.query(pid, sql, [table]) do
      {:ok, result} -> {:ok, result.rows}
      {:error, reason} -> {:error, {:query_error, reason}}
    end
  end

  @doc """
  Verifies every column in `not_null_columns` is schema-guaranteed
  `NOT NULL` (not wrapped `Nullable(...)`) against `table`'s own real
  schema via `conn`. **Not run inside a transaction with the compiled
  query that follows it** -- see `Scry.Engine.Ch.SqlCompiler`'s own
  moduledoc for why ClickHouse structurally can't offer that guarantee
  the way `scry_engine_exqlite`/`scry_engine_duckdbex` both can.
  """
  @spec verify(Conn.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def verify(_conn, _table, []), do: :ok

  def verify(conn, table, not_null_columns) do
    case columns(conn, table) do
      {:ok, rows} -> verify_schema(rows, not_null_columns)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  `Scry.Core.EngineBehaviour`'s optional `describe_source/2` callback,
  proper -- converts `source`'s own real `system.columns` rows into
  `Scry.Core.EngineBehaviour.introspected_field()`s.
  """
  @spec describe_source(Conn.t(), String.t()) ::
          {:ok, [EngineBehaviour.introspected_field()]}
          | {:error, :not_found}
          | {:error, {:introspection_error, term()}}
  def describe_source(conn, source) do
    case columns(conn, source) do
      {:ok, []} -> {:error, :not_found}
      {:ok, rows} -> {:ok, Enum.map(rows, &introspected_field/1)}
      {:error, reason} -> {:error, {:introspection_error, reason}}
    end
  end

  defp introspected_field([name, type]) do
    %{name: to_string(name), nullable: nullable?(type), scalar: introspected_scalar(type)}
  end

  defp nullable?(type), do: String.starts_with?(type, "Nullable(")

  defp unwrap_nullable("Nullable(" <> rest), do: String.trim_trailing(rest, ")")
  defp unwrap_nullable(type), do: type

  defp unwrap_low_cardinality("LowCardinality(" <> rest), do: String.trim_trailing(rest, ")")
  defp unwrap_low_cardinality(type), do: type

  @integer_types ~w(
    Int8 Int16 Int32 Int64 Int128 Int256
    UInt8 UInt16 UInt32 UInt64 UInt128 UInt256
  )

  # A deliberately honest translation of ClickHouse's own real,
  # declared column types into `introspected_field()`'s own scalar
  # vocabulary -- `Bool` is genuinely its own declared type name here
  # (unlike SQLite/DuckDB's affinity-driven guessing), even though it
  # stores as `UInt8` underneath (`Scry.Engine.Ch.WhereTranslator`'s
  # own moduledoc has the full reasoning for why that same fact makes
  # a boolean `WHERE` literal unsafe to translate at all). `Decimal`
  # reports `:unknown`, not `:float`, matching `Scry.Engine.Duckdbex.
  # Schema`'s own identical choice and for the identical reason: its
  # own row values don't come back as a native Elixir float.
  defp introspected_scalar(type) do
    base = type |> unwrap_nullable() |> unwrap_low_cardinality()

    cond do
      base in @integer_types -> :integer
      base in ~w(Float32 Float64) -> :float
      base in ~w(String UUID) or String.starts_with?(base, "FixedString(") -> :string
      base == "Bool" -> :boolean
      base == "JSON" -> :json
      true -> :unknown
    end
  end

  defp verify_schema(rows, not_null_columns) do
    guaranteed_not_null =
      rows
      |> Enum.reject(fn [_name, type] -> nullable?(type) end)
      |> MapSet.new(fn [name, _type] -> to_string(name) end)

    if Enum.all?(not_null_columns, &MapSet.member?(guaranteed_not_null, &1)) do
      :ok
    else
      {:error, {:unsupported, {:nullable_column, not_null_columns}}}
    end
  end
end
