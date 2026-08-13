defmodule Scry.Engine.Ch.SchemaTest do
  use ExUnit.Case, async: false

  alias Scry.Engine.Ch.{Conn, Schema}

  setup_all do
    {:ok, conn} = Conn.open()
    {:ok, conn: conn}
  end

  setup %{conn: conn} do
    {:ok, _} = Ch.query(conn.pid, "DROP TABLE IF EXISTS t")

    {:ok, _} =
      Ch.query(conn.pid, """
      CREATE TABLE t (
        id Int32,
        name String,
        nickname Nullable(String)
      ) ENGINE = MergeTree() ORDER BY id
      """)

    :ok
  end

  describe "columns/2" do
    test "reports name/type pairs in declared column order", %{conn: conn} do
      assert {:ok, rows} = Schema.columns(conn, "t")

      assert Enum.map(rows, fn [name, type] -> [to_string(name), type] end) == [
               ["id", "Int32"],
               ["name", "String"],
               ["nickname", "Nullable(String)"]
             ]
    end

    test "a genuinely unknown table is an empty result, not an error", %{conn: conn} do
      assert Schema.columns(conn, "ghost_table_xyz") == {:ok, []}
    end
  end

  describe "verify/3" do
    test "every not_null_columns entry not wrapped Nullable(...) is :ok", %{conn: conn} do
      assert Schema.verify(conn, "t", ["id", "name"]) == :ok
    end

    test "a Nullable(...) column among not_null_columns declines", %{conn: conn} do
      assert Schema.verify(conn, "t", ["nickname"]) ==
               {:error, {:unsupported, {:nullable_column, ["nickname"]}}}
    end

    test "an empty not_null_columns list is always :ok, even for an unknown table", %{conn: conn} do
      assert Schema.verify(conn, "ghost_table_xyz", []) == :ok
    end

    test "an unknown table's own column is treated as not guaranteed not-null, same as a nullable one",
         %{conn: conn} do
      assert Schema.verify(conn, "ghost_table_xyz", ["id"]) ==
               {:error, {:unsupported, {:nullable_column, ["id"]}}}
    end
  end

  describe "describe_source/2" do
    test "converts real schema rows into introspected_field()s", %{conn: conn} do
      assert {:ok, fields} = Schema.describe_source(conn, "t")
      by_name = Map.new(fields, &{&1.name, &1})

      assert by_name["id"] == %{name: "id", nullable: false, scalar: :integer}
      assert by_name["name"] == %{name: "name", nullable: false, scalar: :string}
      assert by_name["nickname"] == %{name: "nickname", nullable: true, scalar: :string}
    end

    test "an unknown source is {:error, :not_found}", %{conn: conn} do
      assert Schema.describe_source(conn, "ghost_table_xyz") == {:error, :not_found}
    end

    test "a Bool column reports :boolean", %{conn: conn} do
      {:ok, _} = Ch.query(conn.pid, "DROP TABLE IF EXISTS flags")

      {:ok, _} =
        Ch.query(
          conn.pid,
          "CREATE TABLE flags (active Bool) ENGINE = MergeTree() ORDER BY tuple()"
        )

      assert {:ok, [field]} = Schema.describe_source(conn, "flags")
      assert field.scalar == :boolean
    end

    test "a Decimal column reports :unknown, not :float", %{conn: conn} do
      {:ok, _} = Ch.query(conn.pid, "DROP TABLE IF EXISTS money")

      {:ok, _} =
        Ch.query(
          conn.pid,
          "CREATE TABLE money (amount Decimal(10,2)) ENGINE = MergeTree() ORDER BY tuple()"
        )

      assert {:ok, [field]} = Schema.describe_source(conn, "money")
      assert field.scalar == :unknown
    end
  end
end
