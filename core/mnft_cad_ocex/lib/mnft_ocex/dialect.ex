defmodule MnftOcex.Dialect do
  @moduledoc """
  Schema and static validation for the `ocex` JSON construction dialect.

  The dialect is a straight-line stack program: every op pushes a shape,
  consumes the top two shapes for a boolean, or transforms the top shape.
  Validation happens before any native call, so malformed programs fail at
  `:static_check` without touching OCEx.

  Ops (millimetre units):

      box       {"size": [x, y, z], "at": [x, y, z]?}   corner-anchored solid
      cylinder  {"r": r, "h": h, "at": [x, y, z]?}      base-centred, extends +z
      sphere    {"r": r, "at": [x, y, z]?}              centred at `at`
      translate {"delta": [dx, dy, dz]}                 moves the top shape
      union | cut | intersect                          consumes the top two
      fillet_all {"r": r}                               rounds every edge

  Extra keys are ignored; missing or malformed required keys are rejected.
  """

  @max_ops 200
  @max_code_bytes 20_000
  @max_coord 1.0e5
  @min_positive 1.0e-6

  @stack_ops ~w(union cut intersect)
  @shape_ops ~w(box cylinder sphere)
  @known_ops @shape_ops ++ @stack_ops ++ ~w(translate fillet_all)

  @spec validate(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def validate(code) when is_binary(code) do
    if byte_size(code) > @max_code_bytes do
      {:error, "ocex: program exceeds #{@max_code_bytes} bytes"}
    else
      with {:ok, %{"ops" => ops}} <- decode(code),
           {:ok, ops} <- check_list(ops),
           :ok <- check_each(ops) do
        {:ok, ops}
      end
    end
  end

  def validate(_other), do: {:error, "ocex: program must be a JSON string"}

  # --- program shape -----------------------------------------------------------

  defp decode(code) do
    case Jason.decode(code) do
      {:ok, %{"ops" => _} = program} ->
        {:ok, program}

      {:ok, _other} ->
        {:error, "ocex: program must be a JSON object with an \"ops\" array"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "ocex: invalid JSON (#{Exception.message(error)})"}
    end
  end

  defp check_list(ops) when is_list(ops) and ops != [] do
    if length(ops) <= @max_ops,
      do: {:ok, ops},
      else: {:error, "ocex: more than #{@max_ops} ops"}
  end

  defp check_list([]),
    do: {:error, "ocex: \"ops\" is empty — the program must produce one shape"}

  defp check_list(_other), do: {:error, "ocex: \"ops\" must be a non-empty array"}

  defp check_each(ops) do
    ops
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {op, i}, :ok ->
      case check_op(op, i) do
        :ok -> {:cont, :ok}
        {:error, msg} -> {:halt, {:error, msg}}
      end
    end)
  end

  # --- per-op ------------------------------------------------------------------

  defp check_op(%{"op" => name} = op, i) when is_binary(name) do
    if name in @known_ops do
      check_params(name, op, i)
    else
      {:error,
       "ocex: op #{i}: unknown op \"#{name}\" (known: #{Enum.join(Enum.sort(@known_ops), ", ")})"}
    end
  end

  defp check_op(_other, i),
    do: {:error, "ocex: op #{i}: every op must be an object with an \"op\" key"}

  defp check_params("box", op, i),
    do: vec3(op, "size", i, &positive_num?/1, "positive numbers of millimetres below #{@max_coord}")

  defp check_params("cylinder", op, i) do
    with :ok <- positive(op, "r", i), do: positive(op, "h", i)
  end

  defp check_params("sphere", op, i), do: positive(op, "r", i)
  defp check_params("translate", op, i), do: vec3(op, "delta", i, &coord?/1, "finite numbers")
  defp check_params("fillet_all", op, i), do: positive(op, "r", i)

  defp check_params(name, op, i) when name in @stack_ops do
    case Map.fetch(op, "at") do
      :error -> :ok
      {:ok, _} -> {:error, "ocex: op #{i}: \"#{name}\" takes no \"at\""}
    end
  end

  defp check_params(_name, _op, _i), do: :ok

  # --- value helpers -----------------------------------------------------------

  defp positive(op, key, i) do
    case Map.fetch(op, key) do
      {:ok, value} ->
        if positive_num?(value),
          do: :ok,
          else:
            {:error,
             "ocex: op #{i}: \"#{key}\" must be a positive number of millimetres below #{@max_coord}"}

      :error ->
        {:error, "ocex: op #{i}: missing \"#{key}\""}
    end
  end

  defp vec3(op, key, i, predicate, requirement) do
    case Map.fetch(op, key) do
      {:ok, [x, y, z] = value} when is_number(x) and is_number(y) and is_number(z) ->
        if Enum.all?(value, predicate),
          do: :ok,
          else: {:error, "ocex: op #{i}: \"#{key}\" entries must be #{requirement}"}

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"#{key}\" must be a [x, y, z] array of numbers"}

      :error ->
        {:error, "ocex: op #{i}: missing \"#{key}\""}
    end
  end

  defp positive_num?(value) when is_number(value) do
    finite?(value) and value >= @min_positive and value <= @max_coord
  end

  defp positive_num?(_other), do: false

  defp coord?(value) when is_number(value), do: finite?(value) and abs(value) <= @max_coord
  defp coord?(_other), do: false

  defp finite?(value) when is_float(value), do: abs(value) <= Float.max_finite()
  defp finite?(value) when is_integer(value), do: true
  defp finite?(_other), do: false
end
