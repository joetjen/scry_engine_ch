defmodule Scry.Engine.Ch.SqlCompiler do
  @moduledoc """
  Compiles a flat `Scry.Core.Query.t()` into one native SQL statement
  -- `WHERE`/`GROUP BY`/aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/
  `OFFSET`/projection, all in one query -- for `Scry.Engine.Ch`'s own
  `execute/3`. All-or-nothing, the same `Scry.Core.EngineBehaviour.
  execute/3` posture `scry_engine_exqlite`/`scry_engine_duckdbex`
  already established: `compile/2` returns `{:error, {:unsupported,
  detail}}` the moment *anything* in `query` falls outside what this
  module translates, never a partial statement silently dropping part
  of the query's own semantics.

  ## What compiles

  - `wheres`: delegated to `Scry.Engine.Ch.WhereTranslator`, whose own
    moduledoc has the exact predicate shapes it accepts.
  - A **plain** (non-aggregate) query: every `select` item must be a
    bare, single-segment `{:field, [column]}`, optionally under an
    explicit alias -- a genuine computed expression (a cast,
    arithmetic, `WHEN`, a window function) has no translation here and
    declines the whole query.
  - An **aggregate**-shaped query (`group_bys != []`, or any
    `sum`/`avg`/`count`/`min`/`max` call anywhere in `select`):
    `group_mode: :plain` only (`ROLLUP`/`CUBE` decline); every
    `select` item is either a bare field matching one of `group_bys`
    exactly, or one of `sum`/`avg`/`count`/`min`/`max` called with
    exactly one bare-field argument (`count(distinct field)`
    included); `havings == []` (deferred, not attempted this
    increment).
  - `order_bys`: every entry's own sort key must be a bare,
    single-segment field.
  - `distinct`/`limit`/`offset`: always compile directly. ClickHouse
    accepts a bare `OFFSET n` with no `LIMIT` at all, confirmed
    directly against a real server -- the same real capability
    `scry_engine_duckdbex` already found, unlike SQLite's own `LIMIT
    -1 OFFSET n` workaround.

  ## What this compiler does *not* need for numeric/string types, confirmed directly

  ClickHouse's own bound-parameter type checking is strict for
  genuinely incompatible types (a non-numeric string bound against an
  `Int32` column is a real, clean server error, confirmed directly --
  `Code: 53 ... TYPE_MISMATCH`), and its cross-width numeric widening
  (an `Int64`-typed parameter against a narrower `Int32` column, or a
  `Float64` parameter against it) is genuinely correct, not silently
  wrong. This compiler therefore collects no schema-level type-check
  set the way `scry_engine_exqlite`'s own SQLite-targeting compiler
  does -- a real, non-boolean type mismatch already surfaces as this
  package's own honest `{:query_error, ...}` the moment the compiled
  statement runs.

  **One real, confirmed exception**: `Scry.Engine.Ch.WhereTranslator`
  declines every boolean `WHERE` literal outright, unlike `scry_engine_
  duckdbex`'s own -- see that module's own moduledoc for the full,
  confirmed-empirically reasoning (ClickHouse's `Bool`/integer numeric
  coercion, a real silent-wrong-result risk this compiler has no
  schema visibility to guard against any other way).

  ## The one correctness check this compiler still needs: `NOT NULL`

  SQL's own `WHERE`/aggregate functions silently treat a `NULL` column
  value as "doesn't match"/"skip this value," independent of type
  strictness -- a three-valued logic with no way to *raise* the way
  `Scry.Core.QueryOps.eval_predicate/4`'s own null-safety hard error
  does. `compile/2` therefore still returns the set of columns that
  need a schema-level `NOT NULL` guarantee (in ClickHouse's own
  vocabulary: *not* wrapped in `Nullable(...)`) before the compiled
  SQL can be trusted -- every column compared against a non-`nil`
  literal anywhere in `wheres` (the `field = nil`/`field != nil`
  null-check idiom itself is exempt), plus every aggregated column.
  `Scry.Engine.Ch.execute/3` is the one that actually checks this
  (`system.columns`) -- **not inside a shared transaction with the
  compiled query**, unlike `scry_engine_exqlite`/`scry_engine_duckdbex`
  both can offer: ClickHouse has no standard multi-statement
  transaction concept over its HTTP interface at all (confirmed --
  neither the server nor the `ch` driver expose one), so this check is
  necessarily best-effort, immediately before the query rather than
  atomically with it. A schema change on another connection in the
  narrow window between the two is a real, accepted, honestly-stated
  gap this package can't structurally close the way its SQLite/DuckDB
  siblings do.
  """

  alias Scry.Core.Query
  alias Scry.Engine.Ch.WhereTranslator

  @aggregate_names ~w(sum avg count min max)
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @typedoc "A compiled statement, ready to run once any `not_null_columns` check passes."
  @type compiled :: %{sql: String.t(), bind_params: [term()], not_null_columns: [String.t()]}

  @spec compile(Query.t(), map()) :: {:ok, compiled()} | {:error, {:unsupported, term()}}
  def compile(%Query{} = query, params) do
    with {:ok, table} <- table_name(query.source),
         {:ok, where_sql, where_params} <- where_clause(query.wheres, params) do
      if aggregate_query?(query) do
        compile_aggregate(query, table, where_sql, where_params)
      else
        compile_plain(query, table, where_sql, where_params)
      end
    end
  end

  defp where_clause(wheres, params) do
    case WhereTranslator.translate(wheres, params) do
      {:ok, sql, bound} -> {:ok, sql, bound}
      :error -> {:error, {:unsupported, {:predicate, :untranslatable}}}
    end
  end

  defp table_name([table]) when is_binary(table) do
    if Regex.match?(@identifier, table),
      do: {:ok, table},
      else: {:error, {:unsupported, {:source, table}}}
  end

  defp table_name(source), do: {:error, {:unsupported, {:source, source}}}

  # ---- plain (non-aggregate) queries --------------------------------------

  defp compile_plain(query, table, where_sql, where_params) do
    with {:ok, select_sql} <- plain_select_list(query.select),
         {:ok, order_sql} <- order_by_clause(query.order_bys) do
      distinct_sql = if query.distinct, do: "DISTINCT ", else: ""
      limit_sql = limit_offset_clause(query.limit, query.offset)

      sql =
        "SELECT " <>
          distinct_sql <> select_sql <> " FROM " <> table <> where_sql <> order_sql <> limit_sql

      {:ok,
       %{
         sql: sql,
         bind_params: where_params,
         not_null_columns: not_null_columns_from_where(query.wheres)
       }}
    end
  end

  defp plain_select_list([]), do: {:error, {:unsupported, {:select, :empty}}}

  defp plain_select_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case plain_select_item(item) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        :error -> {:halt, {:error, {:unsupported, {:select, item}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.join(Enum.reverse(reversed), ", ")}
      error -> error
    end
  end

  defp plain_select_item({:field, [field]}) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} AS #{quote_ident(field)}"}
    else
      :error
    end
  end

  defp plain_select_item({:computed, alias_name, {:field, [field]}}) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} AS #{quote_ident(alias_name)}"}
    else
      :error
    end
  end

  defp plain_select_item(_other), do: :error

  # ---- aggregate-shaped queries --------------------------------------------

  defp aggregate_query?(query),
    do: query.group_bys != [] or Enum.any?(query.select, &aggregate_body_item?/1)

  defp aggregate_body_item?({:computed, _alias, {:call, name, _args}}),
    do: name in @aggregate_names

  defp aggregate_body_item?(_other), do: false

  defp compile_aggregate(query, table, where_sql, where_params) do
    with :ok <- check(query.group_mode == :plain, {:construct, query.group_mode}),
         :ok <- check(query.havings == [], {:construct, :having}),
         {:ok, group_by_cols} <- group_by_columns(query.group_bys),
         {:ok, select_items} <- aggregate_select_list(query.select, group_by_cols) do
      select_sql = Enum.map_join(select_items, ", ", & &1.sql)
      group_by_sql = group_by_clause(group_by_cols)
      sql = "SELECT " <> select_sql <> " FROM " <> table <> where_sql <> group_by_sql

      not_null_columns =
        (not_null_columns_from_where(query.wheres) ++ Enum.flat_map(select_items, & &1.not_null))
        |> Enum.uniq()

      {:ok, %{sql: sql, bind_params: where_params, not_null_columns: not_null_columns}}
    end
  end

  defp check(true, _detail), do: :ok
  defp check(false, detail), do: {:error, {:unsupported, detail}}

  defp group_by_columns(group_bys) do
    columns = Enum.map(group_bys, &hd/1)

    if Enum.all?(columns, &WhereTranslator.identifier?/1) do
      {:ok, columns}
    else
      {:error, {:unsupported, {:group_by, group_bys}}}
    end
  end

  defp group_by_clause([]), do: ""
  defp group_by_clause(columns), do: " GROUP BY " <> Enum.join(columns, ", ")

  defp aggregate_select_list(items, group_by_cols) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case aggregate_select_item(item, group_by_cols) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        :error -> {:halt, {:error, {:unsupported, {:select, item}}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp aggregate_select_item({:field, [field]}, group_by_cols) do
    if field in group_by_cols do
      {:ok, %{sql: "#{field} AS #{quote_ident(field)}", not_null: []}}
    else
      :error
    end
  end

  defp aggregate_select_item({:computed, alias_name, {:field, [field]}}, group_by_cols) do
    if field in group_by_cols do
      {:ok, %{sql: "#{field} AS #{quote_ident(alias_name)}", not_null: []}}
    else
      :error
    end
  end

  defp aggregate_select_item(
         {:computed, alias_name, {:call, "count", [{:distinct, {:field, [column]}}]}},
         _group_by_cols
       ) do
    if WhereTranslator.identifier?(column) do
      {:ok, %{sql: "COUNT(DISTINCT #{column}) AS #{quote_ident(alias_name)}", not_null: [column]}}
    else
      :error
    end
  end

  defp aggregate_select_item(
         {:computed, alias_name, {:call, name, [{:field, [column]}]}},
         _group_by_cols
       )
       when name in @aggregate_names do
    if WhereTranslator.identifier?(column) do
      {:ok,
       %{
         sql: "#{sql_function(name)}(#{column}) AS #{quote_ident(alias_name)}",
         not_null: [column]
       }}
    else
      :error
    end
  end

  defp aggregate_select_item(_other, _group_by_cols), do: :error

  defp sql_function("sum"), do: "SUM"
  defp sql_function("avg"), do: "AVG"
  defp sql_function("count"), do: "COUNT"
  defp sql_function("min"), do: "MIN"
  defp sql_function("max"), do: "MAX"

  # ---- ORDER BY / LIMIT / OFFSET -------------------------------------------

  defp order_by_clause([]), do: {:ok, ""}

  defp order_by_clause(order_bys) do
    order_bys
    |> Enum.reduce_while({:ok, []}, fn {path, direction}, {:ok, acc} ->
      case order_by_item(path, direction) do
        {:ok, sql} -> {:cont, {:ok, [sql | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, " ORDER BY " <> Enum.join(Enum.reverse(reversed), ", ")}
      :error -> {:error, {:unsupported, {:order_by, order_bys}}}
    end
  end

  defp order_by_item([field], direction) when direction in [:asc, :desc],
    do: order_by_field(field, direction)

  defp order_by_item({:field, [field]}, direction) when direction in [:asc, :desc],
    do: order_by_field(field, direction)

  defp order_by_item(_path, _direction), do: :error

  defp order_by_field(field, direction) do
    if WhereTranslator.identifier?(field) do
      {:ok, "#{field} #{if direction == :asc, do: "ASC", else: "DESC"}"}
    else
      :error
    end
  end

  # ClickHouse accepts a bare `OFFSET n` with no `LIMIT` at all --
  # confirmed directly against a real server.
  defp limit_offset_clause(nil, nil), do: ""
  defp limit_offset_clause(limit, nil) when is_integer(limit), do: " LIMIT #{limit}"
  defp limit_offset_clause(nil, offset) when is_integer(offset), do: " OFFSET #{offset}"

  defp limit_offset_clause(limit, offset) when is_integer(limit) and is_integer(offset),
    do: " LIMIT #{limit} OFFSET #{offset}"

  # ---- NOT NULL column collection (WHERE side) ----------------------------

  defp not_null_columns_from_where(wheres),
    do: wheres |> Enum.flat_map(&collect_not_null/1) |> Enum.uniq()

  defp collect_not_null({:cmp, op, [_field], nil}) when op in [:eq, :not_eq], do: []
  defp collect_not_null({:cmp, _op, [field], _value}), do: [field]
  defp collect_not_null({:in, _lhs, _values}), do: []
  defp collect_not_null({:and, l, r}), do: collect_not_null(l) ++ collect_not_null(r)
  defp collect_not_null({:or, l, r}), do: collect_not_null(l) ++ collect_not_null(r)
  defp collect_not_null({:not, p}), do: collect_not_null(p)
  defp collect_not_null(_other), do: []

  # ---- identifier quoting for output aliases -------------------------------

  # Unlike a *column reference* (validated against `@identifier` and
  # never quoted), a select item's own output alias can be any string
  # a query author chose -- ClickHouse accepts standard SQL
  # double-quote identifier quoting (confirmed directly, including an
  # alias containing a space), doubling an embedded `"` the same way
  # `scry_engine_exqlite`/`scry_engine_duckdbex` already quote theirs.
  defp quote_ident(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
