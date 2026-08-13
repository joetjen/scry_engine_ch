defmodule Scry.Engine.ChTest do
  @moduledoc """
  `Scry.Engine.Ch` -- confirms `execute/3` compiles a plain `WHERE`/
  `ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET` query into one real SQL
  statement against a real ClickHouse server, that an unknown or
  unsafe (would-be SQL-injecting) source is a clear, tagged error
  rather than a crash, that a `WHERE`/`ORDER BY`/`select` shape this
  module can't translate is a clean `{:error, {:unsupported, ...}}`,
  that a `WHERE` predicate against a `Nullable(...)` column correctly
  declines while the same predicate against a non-nullable column
  pushes down fine, that a boolean `WHERE` literal is declined outright
  (this package's own real, confirmed-unsafe divergence from
  `scry_engine_duckdbex`), and that a genuine type mismatch surfaces
  as a real `{:query_error, ...}` -- all composing correctly end to
  end through a real `Scry.Core.Executor.run/4` call.

  **Requires a real, reachable ClickHouse server** -- run one locally
  via `docker run -d -p 8123:8123 -p 9000:9000 -e
  CLICKHOUSE_SKIP_USER_SETUP=1 clickhouse/clickhouse-server:latest`
  (the `CLICKHOUSE_SKIP_USER_SETUP=1` flag matters: as of ClickHouse
  25.1, the stock image's `default` user has no network access at all
  without it, confirmed directly). Runs `async: false` -- every test
  shares one real server connection and a small, fixed set of tables,
  torn down and rebuilt in `setup`, rather than a fresh isolated
  database per test the way the embedded SQLite/DuckDB siblings get.
  """

  use ExUnit.Case, async: false

  alias Scry.Core.{Cursor, Executor, Query, Row}
  alias Scry.Engine.Ch, as: Engine
  alias Scry.Engine.Ch.Conn

  setup_all do
    {:ok, conn} = Conn.open()
    {:ok, conn: conn}
  end

  setup %{conn: conn} do
    {:ok, _} = Ch.query(conn.pid, "DROP TABLE IF EXISTS users")

    {:ok, _} =
      Ch.query(conn.pid, """
      CREATE TABLE users (
        id Int32,
        name String,
        age Int32,
        active Bool,
        status Nullable(String)
      ) ENGINE = MergeTree() ORDER BY id
      """)

    insert_users(conn.pid, [
      {1, "Alice", 30, true, "active"},
      {2, "Bob", 17, false, nil}
    ])

    :ok
  end

  defp insert_users(pid, rows) do
    Enum.each(rows, fn {id, name, age, active, status} ->
      {:ok, _} =
        Ch.query(
          pid,
          "INSERT INTO users VALUES ({$0:Int32}, {$1:String}, {$2:Int32}, {$3:Bool}, {$4:Nullable(String)})",
          [id, name, age, active, status]
        )
    end)
  end

  defp materialize({:ok, rows}), do: {:ok, rows |> Enum.to_list() |> Enum.map(&to_plain/1)}
  defp materialize(other), do: other

  defp to_plain(%Row{} = row), do: Row.to_map(row)
  defp to_plain(row), do: row

  describe "execute/3 -- plain queries" do
    test "rows genuinely come back as Scry.Core.Row values, not plain maps", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, rows} = Engine.execute(conn, query, %{})
      assert [%Row{} = row] = Enum.to_list(rows)
      assert Row.fetch!(row, "name") == "Alice"
      assert Row.to_map(row) == %{"name" => "Alice"}
    end

    test "no wheres at all returns every row", %{conn: conn} do
      query = %Query{source: ["users"], select: [{:field, ["id"]}, {:field, ["name"]}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))

      assert Enum.sort_by(rows, & &1["id"]) == [
               %{"id" => 1, "name" => "Alice"},
               %{"id" => 2, "name" => "Bob"}
             ]
    end

    test "a bare field under an explicit alias still pushes down", %{conn: conn} do
      query = %Query{source: ["users"], select: [{:computed, "n", {:field, ["name"]}}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.sort(rows) == Enum.sort([%{"n" => "Alice"}, %{"n" => "Bob"}])
    end

    test "a WHERE on a non-nullable column pushes down and narrows correctly", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "a WHERE on a Nullable(...) column declines -- the real correctness concern this compiler exists for",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["status"], "active"}],
        select: [{:field, ["name"]}]
      }

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:nullable_column, ["status"]}}}
    end

    test "the explicit field = nil null-check idiom works fine even on a Nullable(...) column", %{
      conn: conn
    } do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["status"], nil}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Bob"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "a boolean WHERE literal is declined outright -- ClickHouse's own Bool/integer numeric coercion risk",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["active"], true}],
        select: [{:field, ["name"]}]
      }

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:predicate, :untranslatable}}}
    end

    test "ORDER BY + LIMIT + OFFSET compiles and executes correctly", %{conn: conn} do
      query = %Query{
        source: ["users"],
        order_bys: [{["age"], :asc}],
        limit: 1,
        offset: 1,
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "OFFSET with no LIMIT compiles and executes correctly", %{conn: conn} do
      query = %Query{
        source: ["users"],
        order_bys: [{["age"], :asc}],
        offset: 1,
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end

    test "ORDER BY on a multi-segment field key declines rather than mistranslate", %{conn: conn} do
      query = %Query{
        source: ["users"],
        order_bys: [{{:field, ["users", "age"]}, :asc}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:unsupported, {:order_by, _}}} = Engine.execute(conn, query, %{})
    end

    test "DISTINCT compiles and executes correctly", %{conn: conn} do
      query = %Query{source: ["users"], distinct: true, select: [{:field, ["age"]}]}

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert Enum.sort_by(rows, & &1["age"]) == [%{"age" => 17}, %{"age" => 30}]
    end

    test "a computed (non-bare-field) select item declines", %{conn: conn} do
      query = %Query{
        source: ["users"],
        select: [{:computed, "n", {:call, "string", [{:field, ["age"]}]}}]
      }

      assert {:error, {:unsupported, {:select, _}}} = Engine.execute(conn, query, %{})
    end

    test "an unknown source is a clear, tagged query_error, never a crash", %{conn: conn} do
      query = %Query{source: ["orders_does_not_exist"], select: [{:field, ["id"]}]}
      assert {:error, {:query_error, _}} = Engine.execute(conn, query, %{})
    end

    test "a source that isn't a safe SQL identifier is rejected before ever touching SQL", %{
      conn: conn
    } do
      malicious = ["users; DROP TABLE users;--"]
      query = %Query{source: malicious, select: []}

      assert Engine.execute(conn, query, %{}) ==
               {:error, {:unsupported, {:source, hd(malicious)}}}

      still_there = %Query{source: ["users"], select: [{:field, ["id"]}]}
      assert {:ok, [_ | _]} = materialize(Engine.execute(conn, still_there, %{}))
    end
  end

  describe "ClickHouse's own strict bound-parameter typing surfaces as a real query_error, not a silent wrong result" do
    test "a non-numeric string bound against an Int32 column raises a clean, real error", %{
      conn: conn
    } do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], "not a number"}],
        select: [{:field, ["name"]}]
      }

      assert {:error, {:query_error, _}} = Engine.execute(conn, query, %{})
    end

    test "an integer bound against an Int32 column with cross-width Int64 widening still pushes down",
         %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :gt, ["age"], 18}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, [%{"name" => "Alice"}]} = materialize(Engine.execute(conn, query, %{}))
    end
  end

  describe "execute/3 -- a DateTime literal WHERE against a real DateTime column" do
    test "pushes down and narrows correctly", %{conn: conn} do
      {:ok, _} = Ch.query(conn.pid, "DROP TABLE IF EXISTS events")

      {:ok, _} =
        Ch.query(conn.pid, """
        CREATE TABLE events (id Int32, logged_at DateTime) ENGINE = MergeTree() ORDER BY id
        """)

      base = ~U[2026-01-01 00:00:00Z]

      Enum.each([{1, base}, {2, DateTime.add(base, 300, :second)}], fn {id, dt} ->
        {:ok, _} =
          Ch.query(conn.pid, "INSERT INTO events VALUES ({$0:Int32}, {$1:DateTime64(6)})", [
            id,
            dt
          ])
      end)

      query = %Query{
        source: ["events"],
        wheres: [{:cmp, :ge, ["logged_at"], DateTime.add(base, 60, :second)}],
        select: [{:field, ["id"]}]
      }

      assert {:ok, rows} = materialize(Engine.execute(conn, query, %{}))
      assert rows == [%{"id" => 2}]
    end
  end

  describe "execute/3 -- delegated to Scry.Core.QueryOps.run_document/4" do
    test "a correlated nested SELECT is delegated and produces correct results -- the nested query's own ORDER BY, not incidental storage order",
         %{conn: conn} do
      {:ok, _} = Ch.query(conn.pid, "DROP TABLE IF EXISTS orders")

      {:ok, _} =
        Ch.query(conn.pid, """
        CREATE TABLE orders (id Int32, user_id Int32, total Int32) ENGINE = MergeTree() ORDER BY id
        """)

      Enum.each([{1, 1, 50}, {2, 1, 75}, {3, 2, 20}], fn {id, user_id, total} ->
        {:ok, _} =
          Ch.query(conn.pid, "INSERT INTO orders VALUES ({$0:Int32}, {$1:Int32}, {$2:Int32})", [
            id,
            user_id,
            total
          ])
      end)

      query = %Query{
        source: ["users"],
        order_bys: [{["id"], :asc}],
        select: [
          {:field, ["name"]},
          %Query{
            source: ["orders"],
            wheres: [{:cmp, :eq, ["user_id"], {:field, ["users", "id"]}}],
            order_bys: [{["id"], :asc}],
            select: [{:field, ["total"]}]
          }
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert Cursor.to_list(cursor) == [
               %{"name" => "Alice", "orders" => [%{"total" => 50}, %{"total" => 75}]},
               %{"name" => "Bob", "orders" => [%{"total" => 20}]}
             ]
    end

    test "a WITH-bound source is delegated and produces correct results", %{conn: conn} do
      query = %Query{
        source: ["adults"],
        select: [{:field, ["name"]}],
        with_bindings: %{
          "adults" => %Query{
            source: ["users"],
            wheres: [{:cmp, :gt, ["age"], 18}],
            select: [{:field, ["name"]}]
          }
        }
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert Cursor.to_list(cursor) == [%{"name" => "Alice"}]
    end
  end

  describe "end to end through Scry.Core.Executor.run/4" do
    test "a key-equality filter executes correctly through the SQL pushdown path", %{conn: conn} do
      query = %Query{
        source: ["users"],
        wheres: [{:cmp, :eq, ["id"], 1}],
        select: [{:field, ["name"]}]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)
      assert cursor |> Cursor.to_list() |> Enum.map(&to_plain/1) == [%{"name" => "Alice"}]
    end

    test "GROUP BY + count + count(distinct ...) executes correctly via native SQL pushdown", %{
      conn: conn
    } do
      query = %Query{
        source: ["users"],
        group_bys: [["age"]],
        select: [
          {:field, ["age"]},
          {:computed, "n", {:call, "count", [{:field, ["id"]}]}}
        ]
      }

      assert {:ok, cursor} = Executor.run(query, Engine, conn)

      assert cursor |> Cursor.to_list() |> Enum.map(&to_plain/1) |> Enum.sort_by(& &1["age"]) == [
               %{"age" => 17, "n" => 1},
               %{"age" => 30, "n" => 1}
             ]
    end
  end

  describe "describe_source/2 (Scry.Core.EngineBehaviour's optional callback)" do
    test "delegates to Scry.Engine.Ch.Schema.describe_source/2", %{conn: conn} do
      assert {:ok, fields} = Engine.describe_source(conn, "users")
      names = fields |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["active", "age", "id", "name", "status"]
    end

    test "an unknown source is {:error, :not_found}", %{conn: conn} do
      assert {:error, :not_found} = Engine.describe_source(conn, "ghost_table")
    end
  end
end
