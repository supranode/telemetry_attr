# TelemetryAttr

Add [`:telemetry`](https://hexdocs.pm/telemetry) spans to your functions with a single annotation.

Annotating a function with `@telemetry span: event_prefix` is equivalent to wrapping its body in [`:telemetry.span/3`](https://hexdocs.pm/telemetry/telemetry.html#span/3).

## Installation

Add `:telemetry_attr` to the project's dependencies in the `mix.exs` file:

```elixir
def deps do
  [
    {:telemetry_attr, "~> 0.1.0"}
  ]
end
```

And then fetch your project's dependencies: `mix deps.get`

## Usage

`use TelemetryAttr` in any module, then annotate functions with `@telemetry`:

```elixir
defmodule MyApp do
  use TelemetryAttr

  @telemetry span: [:my_app, :create_user]
  def create_user(attrs) do
    # Equivalent to wrapping the body in
    # :telemetry.span([:my_app, :create_user], %{}, fn -> ... end)
  end

  @telemetry span: [:my_app, :list_users], vars: [:count]
  def list_users do
    users = fetch_users()
    count = length(users)
    users
    # count is included in the :stop event metadata
  end

  @telemetry span: [:my_app, :get_user], args: [:id]
  def get_user(id) do
    # id is included in the :start event metadata
  end

  @telemetry span: [:my_app, :action], metadata: %{action: :delete_user}
  def delete_user(id) do
    # %{action: :delete_user} is included in every event's metadata
  end
end
```

The `@telemetry` annotation accepts the following options:

  * `:span` - event prefix passed to `:telemetry.span/3`. Must be a list of atoms. Required.
  * `:args` - list of atoms naming arguments to include in the `:start` event metadata. Each name must match an argument of the function. Defaults to `[]`.
  * `:vars` - list of atoms naming local variables to include in the `:stop` event metadata. Each name must match a variable in scope within the function. Defaults to `[]`.
  * `:metadata` - map with atom keys of additional metadata to include in every event (`:start`, `:stop`, `:exception`). Keys must not conflict with `:args` or `:vars`. Defaults to `%{}`.
  * `:result_key` - atom naming the key under which the function's return value is stored in the `:stop` event metadata. Must not conflict with `:metadata`, `:args`, or `:vars`. Defaults to `:result`.

### Behavior with `rescue`, `catch`, and `after`

When the function defines `rescue`, `catch`, or `after` clauses, the entire body is wrapped in a `try` *inside* the span. As a result:

- The span duration includes time spent in `rescue`, `catch`, and `after`.
- Exceptions handled by `rescue` or `catch` produce a `:stop` event, only unhandled exceptions produce `:exception`.

### Limitation: `:vars` with `rescue`/`catch`

Variables listed in `:vars` must be bound in the `do` block and accessible after the `try` expression. Since Elixir does not leak variables from `try` blocks, a variable bound only inside `rescue` or `catch` cannot be captured.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/supranode/telemetry_attr.

## Copyright and License

`TelemetryAttr` source code is licensed under the [MIT License](LICENSE).
