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
          # Equivalent to wrapping the body in
          # :telemetry.span([:my_app, :create_user], %{}, fn -> ... end)
        end

        @telemetry span: [:my_app, :list_users], vars: [:count]
        def list_users do
          users = fetch_users()
          count = length(users)
          users
          # count is included in the stop event metadata
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

  ## Options

  The `@telemetry` annotation accepts the following options:

    * `:span` - event prefix passed to `:telemetry.span/3`. Must be a
      list of atoms.

    * `:args` - list of atoms naming arguments to include in the :start
      event metadata. Each name must match an argument of the function.
      Defaults to `[]`.

    * `:vars` - list of atoms naming local variables to include in the
      :stop event metadata. Each name must match a variable in scope
      within the function. Defaults to `[]`.

    * `:metadata` - map with atom keys of additional metadata to include
      in every event (`:start`, `:stop`, `:exception`). Keys must not
      conflict with `:args` or `:vars`. Defaults to `%{}`.

    * `:result_key` - atom naming the key under which the function's
      return value is stored in the `:stop` event metadata. Must not
      conflict with `:metadata`, `:args`, or `:vars`. Defaults to
      `:result`.

  ## Behaviour with rescue, catch, and after

  When the function has `rescue`, `catch`, or `after` clauses, the entire body
  is wrapped in a `try` inside the span. This means:

  - The span duration includes the time spent in `rescue`, `catch`,
    and `after`.

  - Exceptions handled by `rescue` or `catch` produce a `:stop` event
    (not `:exception`). Only unhandled exceptions produce an
    `:exception` event.

  ## Limitation: :vars with rescue/catch

  Variables listed in `:vars` must be bound in the `do` block and accessible
  after the `try` expression. Since Elixir does not leak variables from `try`
  blocks, a variable that is only bound inside `rescue` or `catch` cannot be
  captured:

      # This will not compile: `x` is not in scope after the try
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
        case Map.fetch(state, mfa) do
          {:ok, {telemetry_attr, clauses}} ->
            new_state = Map.put(state, mfa, {telemetry_attr, [{args, guards, body} | clauses]})
            Module.put_attribute(env.module, @state_attribute, new_state)

          _ ->
            new_state = Map.put(state, mfa, :skip)
            Module.put_attribute(env.module, @state_attribute, new_state)
        end

      telemetry_attr ->
        if kind in [:defmacro, :defmacrop] do
          raise CompileError,
            description: "@telemetry cannot be used on macro #{name}/#{length(args)}"
        end

        validate_attribute!(telemetry_attr)
        Module.delete_attribute(env.module, :telemetry)

        case Map.fetch(state, mfa) do
          {:ok, :skip} ->
            raise CompileError,
              description:
                "@telemetry must be declared before the first clause of #{name}/#{length(args)}"

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

    if not Keyword.has_key?(telemetry_attr, :span) do
      raise CompileError, description: "@telemetry :span is required"
    end

    if Keyword.get(telemetry_attr, :span) == [] do
      raise CompileError, description: "@telemetry :span cannot be empty"
    end

    for {key, value} <- telemetry_attr do
      if key not in [:args, :metadata, :result_key, :span, :vars] do
        raise CompileError, description: "unknown option :#{key} in @telemetry"
      end

      case key do
        :metadata ->
          if not is_map(value) or not Enum.all?(Map.keys(value), &is_atom/1) do
            raise CompileError,
              description:
                "@telemetry :metadata expects a map with atom keys, got: #{inspect(value)}"
          end

        :result_key ->
          if not is_atom(value) do
            raise CompileError,
              description: "@telemetry :result_key expects an atom, got: #{inspect(value)}"
          end

        _ ->
          if not is_list(value) or not Enum.all?(value, &is_atom/1) do
            raise CompileError,
              description: "@telemetry :#{key} expects a list of atoms, got: #{inspect(value)}"
          end

          if key in [:args, :vars] do
            duplicate_vars = value -- Enum.uniq(value)

            if duplicate_vars != [] do
              raise CompileError,
                description: "@telemetry :#{key} contains duplicates: #{inspect(duplicate_vars)}"
            end
          end
      end
    end

    metadata_keys = Map.keys(Keyword.get(telemetry_attr, :metadata, %{}))
    result_key = Keyword.get(telemetry_attr, :result_key, :result)

    for option <- [:args, :vars],
        var <- Keyword.get(telemetry_attr, option, []),
        var in metadata_keys do
      raise CompileError,
        description: "@telemetry :metadata key :#{var} conflicts with :#{option}"
    end

    cond do
      result_key in metadata_keys ->
        raise CompileError,
          description: "@telemetry result_key: :#{result_key} conflicts with :metadata"

      result_key in Keyword.get(telemetry_attr, :args, []) ->
        raise CompileError,
          description: "@telemetry result_key: :#{result_key} conflicts with :args"

      result_key in Keyword.get(telemetry_attr, :vars, []) ->
        raise CompileError,
          description: "@telemetry result_key: :#{result_key} conflicts with :vars"

      true ->
        :ok
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    state = Module.get_attribute(env.module, @state_attribute, %{})
    Module.delete_attribute(env.module, @state_attribute)

    state
    |> Enum.reject(fn {_, value} -> value == :skip end)
    |> Enum.flat_map(fn {{kind, name, arity}, {telemetry_attr, clauses}} ->
      Module.delete_definition(env.module, {name, arity})

      arg_vars = Keyword.get(telemetry_attr, :args, [])
      vars = Keyword.get(telemetry_attr, :vars, [])
      metadata = Keyword.get(telemetry_attr, :metadata, %{})
      result_key = Keyword.get(telemetry_attr, :result_key, :result)
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
          quote generated: true do
            :telemetry.span(
              unquote(span_event_prefix),
              unquote(quoted_metadata_map(metadata, arg_vars)),
              fn ->
                result = unquote(body)

                {result,
                 Map.put(
                   unquote(quoted_metadata_map(metadata, vars)),
                   unquote(result_key),
                   result
                 )}
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

  defp quoted_metadata_map(metadata, vars) do
    metadata_pairs = Enum.map(metadata, fn {key, value} -> {key, Macro.escape(value)} end)
    var_pairs = Enum.map(vars, &{&1, Macro.var(&1, nil)})
    {:%{}, [], metadata_pairs ++ var_pairs}
  end
end
