defmodule TelemetryAttrTest do
  use ExUnit.Case

  defmodule Sequence do
    @moduledoc false

    @doc "Returns the next sequence number."
    @spec next :: non_neg_integer()
    def next do
      sequence_number = Process.get(:telemetry_attr_test_sequence, 0)
      Process.put(:telemetry_attr_test_sequence, sequence_number + 1)
      sequence_number
    end
  end

  defmodule Samples do
    @moduledoc false

    use TelemetryAttr

    @telemetry span: [:zero_arity]
    def zero_arity, do: :zero_arity

    @telemetry span: [:with_args], args: [:x]
    def with_args(x, _y), do: x

    @telemetry span: [:with_vars], vars: [:count]
    def with_vars(list) do
      count = length(list)
      {list, count}
    end

    @telemetry span: [:raises]
    def raises, do: raise("oops")

    @telemetry span: [:recursive]
    def recursive(0), do: 0
    def recursive(n), do: n + recursive(n - 1)

    @telemetry span: [:guarded], args: [:x], vars: [:x]
    def guarded(x) when is_integer(x), do: {:integer, x}
    def guarded(x) when is_binary(x), do: {:string, x}

    @telemetry span: [:delegated], args: [:x]
    defdelegate delegated(x), to: Enum, as: :sum

    @telemetry span: [:with_after]
    def with_after do
      :hello
    after
      send(self(), {:after, Sequence.next()})
    end

    @telemetry span: [:with_rescue]
    def with_rescue do
      raise "oops"
    rescue
      _ -> :rescued
    end

    @telemetry span: [:with_catch]
    def with_catch do
      throw(:oops)
    catch
      _ -> :caught
    end

    @telemetry span: [:with_metadata], metadata: %{meta: true, version: "1.0"}
    def with_metadata, do: :ok

    @telemetry span: [:with_metadata_and_raise], metadata: %{meta: true}
    def with_metadata_and_raise, do: raise("oops")

    @telemetry span: [:with_result_key], vars: [:result], result_key: :my_result
    def with_result_key do
      result = 42
      {:ok, result}
    end
  end

  test "emits :start and :stop events, including :result in :stop metadata" do
    telemetry_attach(span: [:zero_arity])

    assert Samples.zero_arity() == :zero_arity

    assert_received {[:zero_arity, :start], _, %{}, 0}
    assert_received {[:zero_arity, :stop], _, %{result: :zero_arity}, 1}
  end

  test "named :args are included in :start metadata" do
    telemetry_attach(span: [:with_args])

    assert Samples.with_args(:hello, :ignored) == :hello

    assert_received {[:with_args, :start], _, %{x: :hello}, 0}
    assert_received {[:with_args, :stop], _, %{result: :hello}, 1}
  end

  test "local :vars are included in :stop metadata" do
    telemetry_attach(span: [:with_vars])

    assert Samples.with_vars([1, 2, 3]) == {[1, 2, 3], 3}

    assert_received {[:with_vars, :start], _, %{}, 0}
    assert_received {[:with_vars, :stop], _, %{count: 3, result: {[1, 2, 3], 3}}, 1}
  end

  test "emits :exception with exceptions and re-raises" do
    telemetry_attach(span: [:raises])

    assert_raise RuntimeError, "oops", fn ->
      Samples.raises()
    end

    assert_received {[:raises, :start], _, %{}, 0}

    assert_received {[:raises, :exception], _,
                     %{kind: :error, reason: %RuntimeError{message: "oops"}, stacktrace: _}, 1}
  end

  test "emits one span per call with recursive functions" do
    telemetry_attach(span: [:recursive])

    assert Samples.recursive(2) == 3

    assert_received {[:recursive, :start], _, %{}, 0}
    assert_received {[:recursive, :start], _, %{}, 1}
    assert_received {[:recursive, :start], _, %{}, 2}
    assert_received {[:recursive, :stop], _, %{result: 0}, 3}
    assert_received {[:recursive, :stop], _, %{result: 1}, 4}
    assert_received {[:recursive, :stop], _, %{result: 3}, 5}
  end

  test "emits span events per each matching clause" do
    telemetry_attach(span: [:guarded])

    assert Samples.guarded(42) == {:integer, 42}

    assert_received {[:guarded, :start], _, %{x: 42}, 0}
    assert_received {[:guarded, :stop], _, %{x: 42, result: {:integer, 42}}, 1}

    assert Samples.guarded("hello") == {:string, "hello"}

    assert_received {[:guarded, :start], _, %{x: "hello"}, 2}
    assert_received {[:guarded, :stop], _, %{x: "hello", result: {:string, "hello"}}, 3}
  end

  test "emits span events with delegated functions" do
    telemetry_attach(span: [:delegated])

    assert Samples.delegated([1, 2]) == 3

    assert_received {[:delegated, :start], _, %{x: [1, 2]}, 0}
    assert_received {[:delegated, :stop], _, %{result: 3}, 1}
  end

  test "emits span events for functions with an implicit try (after clause), " <>
         "ensuring it runs within the span" do
    telemetry_attach(span: [:with_after])

    assert Samples.with_after() == :hello

    assert_received {[:with_after, :start], _, %{}, 0}
    assert_received {:after, 1}
    assert_received {[:with_after, :stop], _, %{result: :hello}, 2}
  end

  test "emits span events for functions with an implicit try (rescue clause), " <>
         "ensuring it runs within the span" do
    telemetry_attach(span: [:with_rescue])

    assert Samples.with_rescue() == :rescued

    assert_received {[:with_rescue, :start], _, %{}, 0}
    assert_received {[:with_rescue, :stop], _, %{result: :rescued}, 1}
    refute_received {[:with_catch, :exception], _, _, _}
  end

  test "emits span events for functions with an implicit try (catch clause), " <>
         "ensuring it runs within the span" do
    telemetry_attach(span: [:with_catch])

    assert Samples.with_catch() == :caught

    assert_received {[:with_catch, :start], _, %{}, 0}
    assert_received {[:with_catch, :stop], _, %{result: :caught}, 1}
    refute_received {[:with_catch, :exception], _, _, _}
  end

  test "includes :metadata in :start, :stop, and :exception event metadata" do
    telemetry_attach(span: [:with_metadata])

    assert Samples.with_metadata() == :ok

    assert_received {[:with_metadata, :start], _, %{meta: true, version: "1.0"}, 0}
    assert_received {[:with_metadata, :stop], _, %{meta: true, version: "1.0", result: :ok}, 1}

    telemetry_attach(span: [:with_metadata_and_raise])

    assert_raise RuntimeError, "oops", fn -> Samples.with_metadata_and_raise() end

    assert_received {[:with_metadata_and_raise, :start], _, %{meta: true}, 2}
    assert_received {[:with_metadata_and_raise, :exception], _, %{meta: true}, 3}
  end

  test "accepts a :result_key to customize the result key in :stop metadata" do
    telemetry_attach(span: [:with_result_key])

    assert Samples.with_result_key() == {:ok, 42}

    assert_received {[:with_result_key, :start], _, %{}, 0}
    assert_received {[:with_result_key, :stop], _, %{result: 42, my_result: {:ok, 42}}, 1}
  end

  test "raises a CompileError when :span is missing" do
    assert_raise CompileError, "@telemetry :span is required", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry []
        def sample, do: :ok
      end
      """)
    end
  end

  test "raises a CompileError when @telemetry is not a keyword list" do
    assert_raise CompileError, "expected @telemetry to be a keyword list, got: :sample", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry :sample
        def sample, do: :ok
      end
      """)
    end
  end

  test "raises a CompileError for unknown options" do
    assert_raise CompileError, "unknown option :unknown_option in @telemetry", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: [:sample], unknown_option: true
        def sample, do: :ok
      end
      """)
    end
  end

  test "raises a CompileError when :span is empty" do
    assert_raise CompileError, "@telemetry :span cannot be empty", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: []
        def sample, do: :ok
      end
      """)
    end
  end

  test "raises a CompileError when :args contains duplicates" do
    assert_raise CompileError, "@telemetry :args contains duplicates: [:x]", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: [:sample], args: [:x, :y, :x]
        def sample(x, y), do: {x, y}
      end
      """)
    end
  end

  test "raises a CompileError when :vars contains duplicates" do
    assert_raise CompileError, "@telemetry :vars contains duplicates: [:count]", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: [:sample], vars: [:count, :count]
        def sample do
          count = 1
          count
        end
      end
      """)
    end
  end

  test "raises a CompileError when @telemetry annotates a defmacro" do
    assert_raise CompileError,
                 "@telemetry cannot be used on macro sample/1",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample]
                     defmacro sample(x), do: x
                   end
                   """)
                 end
  end

  test "raises a CompileError when @telemetry annotates a defmacrop" do
    assert_raise CompileError,
                 "@telemetry cannot be used on macro sample/1",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample]
                     defmacrop sample(x), do: x

                     def sample(x, y), do: sample(x) + y
                   end
                   """)
                 end
  end

  test "raises a CompileError when :args is not a list of atoms" do
    assert_raise CompileError, "@telemetry :args expects a list of atoms, got: [\"x\"]", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: [:sample], args: ["x"]
        def sample(x), do: x
      end
      """)
    end
  end

  test "raises a CompileError when :vars is not a list of atoms" do
    assert_raise CompileError, "@telemetry :vars expects a list of atoms, got: [\"x\"]", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: [:sample], vars: ["x"]
        def sample(x), do: x
      end
      """)
    end
  end

  test "raises a CompileError when :metadata is not a map with atom keys" do
    assert_raise CompileError,
                 "@telemetry :metadata expects a map with atom keys, got: [meta: true]",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], metadata: [meta: true]
                     def sample, do: :ok
                   end
                   """)
                 end

    assert_raise CompileError,
                 "@telemetry :metadata expects a map with atom keys, got: %{\"meta\" => true}",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], metadata: %{"meta" => true}
                     def sample, do: :ok
                   end
                   """)
                 end
  end

  test "raises a CompileError when :metadata keys conflict with :args" do
    assert_raise CompileError,
                 "@telemetry :metadata key :x conflicts with :args",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], args: [:x], metadata: %{x: :overridden}
                     def sample(x), do: x
                   end
                   """)
                 end
  end

  test "raises a CompileError when :metadata keys conflict with :vars" do
    assert_raise CompileError,
                 "@telemetry :metadata key :count conflicts with :vars",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], vars: [:count], metadata: %{count: 0}
                     def sample do
                       count = 1
                       count
                     end
                   end
                   """)
                 end
  end

  test "raises CompileError when @telemetry is declared more than once per function" do
    assert_raise CompileError, "@telemetry must be declared at most once per function", fn ->
      Code.compile_string("""
      defmodule Sample do
        use TelemetryAttr

        @telemetry span: [:first]
        def sample(1), do: :first

        @telemetry span: [:last]
        def sample(x), do: x
      end
      """)
    end
  end

  test "raises CompileError when @telemetry is declared after the first clause of a function" do
    assert_raise CompileError,
                 "@telemetry must be declared before the first clause of sample/1",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     def sample(0), do: :zero

                     @telemetry span: [:sample]
                     def sample(n), do: n
                   end
                   """)
                 end
  end

  test "raises a CompileError when :args is not a list" do
    assert_raise CompileError,
                 "@telemetry :args expects a list of atoms, got: :not_a_list",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], args: :not_a_list
                     def sample(x), do: x
                   end
                   """)
                 end
  end

  test "raises a CompileError when :vars is not a list" do
    assert_raise CompileError,
                 "@telemetry :vars expects a list of atoms, got: :not_a_list",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], vars: :not_a_list
                     def sample(x), do: x
                   end
                   """)
                 end
  end

  test "raises a CompileError when :span is not a list" do
    assert_raise CompileError,
                 "@telemetry :span expects a list of atoms, got: :not_a_list",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: :not_a_list
                     def sample, do: :ok
                   end
                   """)
                 end
  end

  test "raises a CompileError when :result_key is not an atom" do
    assert_raise CompileError,
                 "@telemetry :result_key expects an atom, got: \"my_result\"",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], result_key: "my_result"
                     def sample, do: :ok
                   end
                   """)
                 end
  end

  test "raises a CompileError when :result_key conflicts with :metadata" do
    assert_raise CompileError,
                 "@telemetry result_key: :foo conflicts with :metadata",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], result_key: :foo, metadata: %{foo: 1}
                     def sample, do: :ok
                   end
                   """)
                 end
  end

  test "raises a CompileError when :result_key conflicts with :args" do
    assert_raise CompileError,
                 "@telemetry result_key: :x conflicts with :args",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], result_key: :x, args: [:x]
                     def sample(x), do: x
                   end
                   """)
                 end
  end

  test "raises a CompileError when :result_key conflicts with :vars" do
    assert_raise CompileError,
                 "@telemetry result_key: :count conflicts with :vars",
                 fn ->
                   Code.compile_string("""
                   defmodule Sample do
                     use TelemetryAttr

                     @telemetry span: [:sample], result_key: :count, vars: [:count]
                     def sample do
                       count = 1
                       count
                     end
                   end
                   """)
                 end
  end

  defp telemetry_attach(span: span_event_prefix) do
    handler_id = make_ref()
    event_names = Enum.map([:start, :stop, :exception], &(span_event_prefix ++ [&1]))

    :telemetry.attach_many(handler_id, event_names, &__MODULE__.telemetry_handler/4, nil)
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Avoid warnings from `:telemetry` when using anonymous or local functions
  # as handlers in `:telemetry.attach/4` or `:telemetry.attach_many/4`.
  #
  # See the note in the `:telemetry.attach/4` documentation for details.
  @doc false
  def telemetry_handler(event_name, measurements, metadata, _config),
    do: send(self(), {event_name, measurements, metadata, Sequence.next()})
end
