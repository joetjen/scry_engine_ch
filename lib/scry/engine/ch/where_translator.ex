defmodule Scry.Engine.Ch.WhereTranslator do
  @moduledoc """
  Translates a `Scry.Core.Query.t()`'s own `wheres` into a real SQL
  `WHERE` clause with bound, explicitly-typed `{$0:Type}, {$1:Type},
  ...` parameters -- ClickHouse's own query-parameter syntax, confirmed
  directly against a real server: unlike SQLite's `?` or DuckDB's
  `$1`, ClickHouse has no untyped placeholder at all -- every bound
  value's own ClickHouse type has to be spelled out inline in the SQL
  text itself, or the server rejects the query outright. Every
  recursive helper threads a running, zero-based placeholder counter
  through the whole predicate tree (matching `ch`'s own `{$0:...}`,
  `{$1:...}` numbering, confirmed directly -- zero-based, unlike
  `scry_engine_duckdbex`'s one-based `$1`) so each new value gets a
  globally correct, sequential number the first time, the same
  threading technique that module's own `WhereTranslator` uses.

  All-or-nothing: `translate/2` returns `:error` the moment *any*
  predicate anywhere in the tree can't be translated, never a partial
  clause silently narrowing what ClickHouse returns. A full recursive
  `{:and, l, r}`/`{:or, l, r}`/`{:not, p}` tree translates, not just a
  flat, implicitly-`AND`ed list of leaves -- each combinator becomes
  its own parenthesized SQL group so operator precedence can never
  differ from what the predicate tree itself already encodes.

  Only `{:cmp, op, [field], value}` and `{:in, [field], values}` leaves
  are candidates, and only when: `field` is a single segment that's
  also a valid, safe-to-interpolate SQL identifier; `op` is one of
  `:eq`/`:not_eq`/`:lt`/`:gt`/`:le`/`:ge` (`:match` has no native
  ClickHouse equivalent); and every value involved (a literal, or a
  `{:param, name}` resolved against `params`) is a plain string,
  integer, float, a `DateTime.t()`/`NaiveDateTime.t()` (bound with
  their own real, native `DateTime64(6)` type -- `ch` accepts an
  Elixir `DateTime`/`NaiveDateTime` struct directly, confirmed, unlike
  `duckdbex` which needs a string), **or** the literal `nil`
  specifically for `:eq`/`:not_eq` -- translated to `IS NULL`/`IS NOT
  NULL`, not a naive `= {$N:Type}`/`!= {$N:Type}` bound to `NULL`.

  ## Booleans are declined, unlike `scry_engine_duckdbex`'s own -- a real, confirmed-empirically ClickHouse-specific risk

  Not for the same reason `scry_engine_exqlite` declines them (SQLite
  simply has no native boolean type at all) -- ClickHouse *does* have
  a real, distinct `Bool` column type, distinguishable in schema
  introspection. The real risk is ClickHouse's own numeric coercion
  between `Bool` and any integer type: confirmed directly against a
  real server, `SELECT {$0:Int32} = {$1:Bool}` with `(1, true)`
  returns `true` -- ClickHouse's own `Bool` is `UInt8`-backed and
  compares numerically equal to `1`, unlike `Scry.Core.QueryOps`'s own
  `Kernel.==/2`-based interpreter semantics, where `1 == true` is
  `false`. Nothing at translation time knows whether the *actual*
  compared column is genuinely `Bool`-typed (this module has no schema
  access) or an ordinary integer column a boolean literal would
  silently, incorrectly compare equal against -- declining the whole
  predicate is the only structurally safe choice available here,
  without adding a schema check `scry_engine_duckdbex` never needed
  (that package's own README/moduledoc has the "no schema-level type
  check needed here" finding this module's own `Bool` exception is
  carved out of, for this one real, confirmed-unsafe case only).
  """

  alias Scry.Core.Query

  @op_sql %{eq: "=", not_eq: "!=", lt: "<", gt: ">", le: "<=", ge: ">="}
  @identifier ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Returns `{:ok, where_sql, params}` -- `where_sql` is either `""`
  (an empty `wheres`) or a `" WHERE ..."` fragment (leading space
  included), `params` the bound values in the same left-to-right
  order as the `{$0:...}, {$1:...}, ...` placeholders -- or `:error`
  the moment anything in `wheres` doesn't translate.
  """
  @spec translate([Query.predicate()], map()) :: {:ok, String.t(), [term()]} | :error
  def translate(wheres, params) do
    wheres
    |> Enum.reduce_while({:ok, [], 0}, fn predicate, {:ok, acc, n} ->
      case translate_predicate(predicate, params, n) do
        {:ok, sql, bound, next_n} -> {:cont, {:ok, [{sql, bound} | acc], next_n}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, [], _n} ->
        {:ok, "", []}

      {:ok, reversed, _n} ->
        {fragments, param_lists} = reversed |> Enum.reverse() |> Enum.unzip()
        {:ok, " WHERE " <> Enum.join(fragments, " AND "), List.flatten(param_lists)}

      :error ->
        :error
    end
  end

  # `{:cmp, op, lhs, nil}`'s own null-check idiom -- `field = NULL` is
  # always `NULL` in SQL, never `TRUE`, so this is a real, dedicated
  # translation, not the general clause below with `nil` bound as an
  # ordinary parameter.
  defp translate_predicate({:cmp, :eq, [field], nil}, _params, n) do
    if identifier?(field), do: {:ok, "#{field} IS NULL", [], n}, else: :error
  end

  defp translate_predicate({:cmp, :not_eq, [field], nil}, _params, n) do
    if identifier?(field), do: {:ok, "#{field} IS NOT NULL", [], n}, else: :error
  end

  defp translate_predicate({:cmp, op, [field], value}, params, n) do
    with {:ok, sql_op} <- Map.fetch(@op_sql, op),
         true <- identifier?(field),
         {:ok, resolved, ch_type} <- resolve_value(value, params) do
      {:ok, "#{field} #{sql_op} {$#{n}:#{ch_type}}", [resolved], n + 1}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:in, [field], values}, params, n) when is_list(values) do
    with true <- identifier?(field),
         {:ok, resolved} when resolved != [] <- resolve_all(values, params, n) do
      {sql_values, bound} = Enum.unzip(resolved)
      placeholders = Enum.join(sql_values, ", ")
      {:ok, "#{field} IN (#{placeholders})", bound, n + length(resolved)}
    else
      _ -> :error
    end
  end

  # `in` against a non-literal-list expr (a field/call expected to
  # resolve to a list at runtime) has no direct SQL translation --
  # declined, not attempted this increment.
  defp translate_predicate({:in, _lhs, _list_expr}, _params, _n), do: :error

  defp translate_predicate({:and, l, r}, params, n) do
    with {:ok, sql_l, params_l, n2} <- translate_predicate(l, params, n),
         {:ok, sql_r, params_r, n3} <- translate_predicate(r, params, n2) do
      {:ok, "(#{sql_l} AND #{sql_r})", params_l ++ params_r, n3}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:or, l, r}, params, n) do
    with {:ok, sql_l, params_l, n2} <- translate_predicate(l, params, n),
         {:ok, sql_r, params_r, n3} <- translate_predicate(r, params, n2) do
      {:ok, "(#{sql_l} OR #{sql_r})", params_l ++ params_r, n3}
    else
      _ -> :error
    end
  end

  defp translate_predicate({:not, p}, params, n) do
    case translate_predicate(p, params, n) do
      {:ok, sql, bound, n2} -> {:ok, "NOT (#{sql})", bound, n2}
      :error -> :error
    end
  end

  # A bare-path/`{:call, ...}`/`{:dot, ...}` `lhs` on a `:cmp` (rather
  # than the `[field]` single-segment shape every clause above already
  # matches) and anything else this module doesn't recognize.
  defp translate_predicate(_other, _params, _n), do: :error

  defp resolve_all(values, params, start_n) do
    values
    |> Enum.reduce_while({:ok, [], start_n}, fn value, {:ok, acc, n} ->
      case resolve_value(value, params) do
        {:ok, resolved, ch_type} ->
          {:cont, {:ok, [{"{$#{n}:#{ch_type}}", resolved} | acc], n + 1}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed, _n} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp resolve_value({:param, name}, params) do
    case Map.fetch(params, name) do
      {:ok, value} -> bind_value(value)
      :error -> :error
    end
  end

  defp resolve_value(value, _params), do: bind_value(value)

  @doc "Whether `field` is a safe-to-interpolate SQL identifier -- also used by `Scry.Engine.Ch.SqlCompiler`."
  @spec identifier?(term()) :: boolean()
  def identifier?(field), do: is_binary(field) and Regex.match?(@identifier, field)

  # `{value, ch_type}` -- `ch_type` is the ClickHouse type name embedded
  # directly in that value's own `{$N:ch_type}` placeholder. Integers
  # always bind as `Int64` (ClickHouse's own cross-width numeric
  # comparison against a narrower real column, e.g. `Int32`, confirmed
  # directly to widen correctly, the same "found real, not assumed"
  # confirmation `scry_engine_duckdbex`'s own moduledoc documents for
  # its own driver). A `DateTime`/`NaiveDateTime` literal always binds
  # as `DateTime64(6)` (microsecond precision) regardless of the
  # value's own actual precision or the compared column's -- confirmed
  # directly: a `DateTime64(6)`-typed parameter compares correctly
  # against an ordinary second-precision `DateTime` column, so there's
  # no need to introspect either side's real precision first.
  @spec bind_value(term()) :: {:ok, term(), String.t()} | :error
  def bind_value(%DateTime{} = value), do: {:ok, value, "DateTime64(6)"}
  def bind_value(%NaiveDateTime{} = value), do: {:ok, value, "DateTime64(6)"}
  def bind_value(value) when is_binary(value), do: {:ok, value, "String"}
  def bind_value(value) when is_integer(value), do: {:ok, value, "Int64"}
  def bind_value(value) when is_float(value), do: {:ok, value, "Float64"}
  def bind_value(_value), do: :error
end
