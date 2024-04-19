defmodule TelemetryAttr do
  @moduledoc """
  Add telemetry events to your functions with a single annotation.

  Annotating a function with `@telemetry span: event_prefix` is equivalent to
  wrapping its body in [`:telemetry.span/3`](https://hexdocs.pm/telemetry/telemetry.html#span/3).

  ## Usage

      defmodule MyApp do
        use TelemetryAttr

        @telemetry span: [:my_app, :create_user]
        def create_user(attrs) do
          # equivalent to wrapping the body in :telemetry.span([:my_app, :create_user], %{}, fn -> ... end)
        end

        @telemetry span: [:my_app, :list_users], vars: [:count]
        def list_users do
          users = fetch_users()
          count = length(users)
          users
          # count is included in the stop event metadata
        end
      end

  ## Options

  - `:span` - event prefix passed to `:telemetry.span/3`.
  - `:args` - list of argument names to include in the start event metadata. Defaults to `[]`.
  - `:vars` - list of local variable names to include in the stop event metadata. Defaults to `[]`.

  ## Behaviour with rescue, catch, and after

  When the function has `rescue`, `catch`, or `after` clauses, the entire body
  is wrapped in a `try` inside the span. This means:

  - The span duration includes the time spent in `rescue`, `catch`, and `after`.
  - Exceptions handled by `rescue` or `catch` produce a `:stop` event (not `:exception`).
    Only unhandled exceptions produce an `:exception` event.

  ## Limitation: :vars with rescue/catch

  Variables listed in `:vars` must be bound in the `do` block and accessible after
  the `try` expression. Since Elixir does not leak variables from `try` blocks, a
  variable that is only bound inside `rescue` or `catch` cannot be captured:

      # This will not compile — `x` is not in scope after the try
      @telemetry span: [:foo], vars: [:x]
      def foo do
        x = compute()
        :ok
      rescue
        _ -> :error
      end
  """

  @state_attribute :"$telemetryattr"

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :telemetry, accumulate: false)
      Module.register_attribute(__MODULE__, unquote(@state_attribute), accumulate: false)

      @on_definition {TelemetryAttr, :__on_definition__}
      @before_compile {TelemetryAttr, :__before_compile__}
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, guards, body) do
    state = Module.get_attribute(env.module, @state_attribute, %{})
    mfa = {kind, name, length(args)}

    case Module.get_attribute(env.module, :telemetry) do
      nil ->
        with {:ok, {telemetry_attr, clauses}} <- Map.fetch(state, mfa) do
          new_state = Map.put(state, mfa, {telemetry_attr, [{args, guards, body} | clauses]})
          Module.put_attribute(env.module, @state_attribute, new_state)
        end

      telemetry_attr ->
        validate_attribute!(telemetry_attr)
        Module.delete_attribute(env.module, :telemetry)

        case Map.fetch(state, mfa) do
          {:ok, _} ->
            raise CompileError,
              description: "@telemetry must be declared at most once per function"

          :error ->
            new_state = Map.put(state, mfa, {telemetry_attr, [{args, guards, body}]})
            Module.put_attribute(env.module, @state_attribute, new_state)
        end
    end
  end

  defp validate_attribute!(telemetry_attr) do
    if not Keyword.keyword?(telemetry_attr) do
      raise CompileError,
        description: "expected @telemetry to be a keyword list, got: #{inspect(telemetry_attr)}"
    end

    for {key, value} <- telemetry_attr do
      if key not in [:args, :span, :vars] do
        raise CompileError, description: "unknown option :#{key} in @telemetry"
      end

      if not Enum.all?(value, &is_atom/1) do
        raise CompileError,
          description: "@telemetry :#{key} expects a list of atoms, got: #{inspect(value)}"
      end
    end

    if not Keyword.has_key?(telemetry_attr, :span) do
      raise CompileError, description: "@telemetry :span is required"
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    state = Module.get_attribute(env.module, @state_attribute, %{})
    Module.delete_attribute(env.module, @state_attribute)

    Enum.flat_map(state, fn {{kind, name, arity}, {telemetry_attr, clauses}} ->
      Module.delete_definition(env.module, {name, arity})

      arg_vars = Keyword.get(telemetry_attr, :args, [])
      vars = Keyword.get(telemetry_attr, :vars, [])
      span_event_prefix = Keyword.get(telemetry_attr, :span, [])

      clauses
      |> Enum.reverse()
      |> Enum.map(fn {args, guards, body} ->
        body =
          case body do
            [do: body] -> body
            _ -> {:try, [], [body]}
          end

        body =
          quote do
            :telemetry.span(
              unquote(span_event_prefix),
              unquote(quoted_metadata_map(arg_vars)),
              fn ->
                result = unquote(body)
                {result, Map.put(unquote(quoted_metadata_map(vars)), :result, result)}
              end
            )
          end

        quote do
          unquote(kind)(unquote(quoted_function_head(name, args, guards)), do: unquote(body))
        end
      end)
    end)
  end

  defp quoted_function_head(name, args, guards) do
    case guards do
      [] -> quote(do: unquote(name)(unquote_splicing(args)))
      _ -> quote(do: unquote(name)(unquote_splicing(args)) when unquote_splicing(guards))
    end
  end

  defp quoted_metadata_map(vars), do: {:%{}, [], Enum.map(vars, &{&1, Macro.var(&1, nil)})}
end
