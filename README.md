# scry_engine_ch

A real, kind-independent [`Scry.Core.EngineBehaviour`](https://github.com/joetjen/scry_core)
implementation over [ClickHouse](https://clickhouse.com/), via the
[`ch`](https://hex.pm/packages/ch) driver. A single authoritative
`execute/3` compiles the *entire* flat query -- `WHERE`/`GROUP BY`/
aggregates/`ORDER BY`/`DISTINCT`/`LIMIT`/`OFFSET`/projection -- into
one native SQL statement, all or nothing: either the whole query is
genuinely correct as native SQL, or `execute/3` declines it with a
clean `{:error, {:unsupported, detail}}` and no attempt is made.

Closes the validation lang_spec.md §12 already commits to (the
time-series kind, framed around "the RabbitMQ/ClickHouse use case") --
none of the engines built before this one (in-memory, ETS, SQLite,
PostgreSQL, DuckDB) exercise a genuine time-series-oriented product.
`scry_time_series`'s own `LAST`-lowering pass already rewrites into an
ordinary `WHERE` predicate before any engine ever sees it, so this
package needs no time-series-specific code of its own -- being a
correct, general `Scry.Core.EngineBehaviour` implementation already
closes the gap.

Source: <https://github.com/joetjen/scry_engine_ch>. Specs live in the
separate [`scry`](https://github.com/joetjen/scry) repository; the
behaviour this implements lives in
[`scry_core`](https://github.com/joetjen/scry_core).

## Usage

```elixir
{:ok, conn} = Scry.Engine.Ch.Conn.open(hostname: "localhost", port: 8123)

{:ok, query} = Scry.Core.parse(~s(SELECT users WHERE id = 1 { name }))
{:ok, cursor} = Scry.Core.Executor.run(query, Scry.Engine.Ch, conn)
rows = Scry.Core.Cursor.to_list(cursor)
# rows == [%{"name" => "Alice"}]
```

`Conn.open/1` starts a real, linked `ch` connection pool (`ch` is
`DBConnection`-based, unlike this package's embedded SQL siblings) --
meant to be reused across many `execute/3` calls, not reopened per
call. An application wanting this connection properly supervised
should add `Ch`'s own `child_spec` to its own supervision tree
directly instead of calling `open/1`.

### Local development / running the test suite

```sh
docker run -d -p 8123:8123 -p 9000:9000 \
  -e CLICKHOUSE_SKIP_USER_SETUP=1 \
  clickhouse/clickhouse-server:latest
```

`CLICKHOUSE_SKIP_USER_SETUP=1` matters: as of ClickHouse 25.1, the
stock image's `default` user has no network access at all without it
-- confirmed directly, not assumed from older documentation.

## What's genuinely different from this package's SQL-engine siblings

Confirmed directly against a real ClickHouse server, not assumed from
either `scry_engine_exqlite` or `scry_engine_duckdbex`'s own precedent:

- **No untyped bind placeholder exists at all.** Every parameter's own
  ClickHouse type has to be spelled out inline in the SQL text
  (`{$0:Int64}`, `{$1:String}`, ...), zero-based -- `WhereTranslator`
  picks the type annotation per Elixir value's own class, relying on
  ClickHouse's own confirmed-correct cross-width numeric widening
  rather than needing to introspect the target column first.
- **Booleans are declined outright**, unlike `scry_engine_duckdbex`'s
  own -- a real, confirmed ClickHouse-specific risk: `Bool` is
  `UInt8`-backed and compares numerically equal to a plain integer
  (`1 = true` is `true` in ClickHouse), which `WhereTranslator`'s own
  moduledoc documents in full. This module has no schema visibility at
  translation time to tell a genuinely `Bool`-typed column apart from
  an ordinary integer one a boolean literal would silently mismatch
  against, so declining is the only structurally safe choice.
- **Nullability is inverted**: a column is `NOT NULL` by default; only
  an explicit `Nullable(...)` type wrapper opts in to `NULL` at all.
- **The `NOT NULL` check runs immediately before the query, not inside
  a shared transaction with it** -- ClickHouse has no standard
  multi-statement transaction concept over its HTTP interface at all,
  so the atomic guarantee its SQLite/DuckDB siblings both offer isn't
  structurally available here.
- **Always eager, never a lazy `Stream`** -- `ch`'s own query function
  returns one fully-materialized result per call; no validated
  chunked-fetch primitive exists to build a lazy cursor on top of.
- **A `SELECT` with no `ORDER BY` has no guaranteed row order** --
  `MergeTree` (ClickHouse's own standard table engine) returns rows in
  physical/merge order, not insertion order. Any query whose row order
  matters, correlated nested `SELECT` body items included, needs an
  explicit `ORDER BY` of its own.

### What this package does *not* need, confirmed directly

ClickHouse's own bound-parameter type checking is strict for
genuinely incompatible types (a real, clean server error, not a
silent wrong comparison) and its cross-width numeric widening is
genuinely correct -- this compiler therefore collects no schema-level
type-affinity check the way `scry_engine_exqlite`'s own SQLite-
targeting compiler needs.

## Installation

```elixir
def deps do
  [
    {:scry_engine_ch, "~> 0.1.0"}
  ]
end
```

## Documentation

Documentation is generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

- Released versions are published to [HexDocs](https://hexdocs.pm) once the
  package ships, at <https://hexdocs.pm/scry_engine_ch>.
