defmodule Scry.Engine.Ch.WhereTranslatorPropertyTest do
  @moduledoc """
  Property coverage for the placeholder-numbering machinery
  `Scry.Engine.Ch.WhereTranslator` needed beyond a straight port of
  its `scry_engine_duckdbex` sibling: ClickHouse's own `{$0:Type},
  {$1:Type}, ...` placeholders are zero-based (confirmed directly,
  unlike DuckDB's one-based `$1`) and each one carries its own inline
  type annotation -- exactly the kind of "must hold for every input"
  invariant AGENTS.md calls for a property test over.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Scry.Engine.Ch.WhereTranslator

  # Booleans are deliberately excluded here -- `WhereTranslator` always
  # declines them (this module's own moduledoc has the confirmed-unsafe
  # reasoning), so a generator including them would make `translate/2`
  # correctly return `:error`, not exercise the numbering invariant.
  defp field_gen do
    StreamData.bind(
      {StreamData.string(?a..?z, length: 1), StreamData.string(:alphanumeric, max_length: 5)},
      fn {first, rest} -> StreamData.constant(first <> rest) end
    )
  end

  defp value_gen,
    do: StreamData.one_of([StreamData.integer(), StreamData.string(:alphanumeric, max_length: 6)])

  defp cmp_gen do
    StreamData.bind({field_gen(), value_gen()}, fn {field, value} ->
      StreamData.constant({:cmp, :eq, [field], value})
    end)
  end

  defp placeholder_numbers(sql) do
    ~r/\{\$(\d+):/
    |> Regex.scan(sql)
    |> Enum.map(fn [_whole, digits] -> String.to_integer(digits) end)
  end

  property "a flat list of :cmp predicates numbers every placeholder sequentially, zero-based" do
    check all(predicates <- StreamData.list_of(cmp_gen(), min_length: 1, max_length: 10)) do
      assert {:ok, sql, bind_params} = WhereTranslator.translate(predicates, %{})

      assert length(bind_params) == length(predicates)
      assert placeholder_numbers(sql) == Enum.to_list(0..(length(predicates) - 1))
    end
  end

  property "a nested AND/OR/NOT tree still numbers every placeholder sequentially, left to right" do
    check all(cmps <- StreamData.list_of(cmp_gen(), min_length: 2, max_length: 8)) do
      tree = Enum.reduce(tl(cmps), hd(cmps), fn cmp, acc -> {:and, acc, {:not, cmp}} end)

      assert {:ok, sql, bind_params} = WhereTranslator.translate([tree], %{})

      assert length(bind_params) == length(cmps)
      assert placeholder_numbers(sql) == Enum.to_list(0..(length(cmps) - 1))
    end
  end

  property "an IN list allocates one consecutive placeholder per value, in order" do
    check all(
            field <- field_gen(),
            values <- StreamData.list_of(value_gen(), min_length: 1, max_length: 10)
          ) do
      assert {:ok, sql, bind_params} = WhereTranslator.translate([{:in, [field], values}], %{})

      assert bind_params == values
      assert placeholder_numbers(sql) == Enum.to_list(0..(length(values) - 1))
    end
  end

  property "every generated value's own type annotation matches its Elixir type" do
    check all(value <- value_gen()) do
      assert {:ok, sql, [^value]} = WhereTranslator.translate([{:cmp, :eq, ["f"], value}], %{})

      expected_type = if is_binary(value), do: "String", else: "Int64"
      assert sql =~ "{$0:#{expected_type}}"
    end
  end
end
