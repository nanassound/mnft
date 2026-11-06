defmodule MnftOcex.Dialect do
  @moduledoc """
  Schema and static validation for the `ocex` JSON construction dialect.

  The dialect is a straight-line stack program: every op pushes a shape,
  consumes the top two shapes for a boolean, or transforms the top shape.
  Validation happens before any native call, so malformed programs fail at
  `:static_check` without touching OCEx.

  29 ops (millimetre units); `Mnft.Cad.PromptOcex` in the core holds the
  normative op table the model is shown, and this module enforces exactly it.

  Rules: missing or malformed required keys are rejected. Unknown keys are
  ignored, with one exception — a malformed `at` is rejected on every op that
  takes it, and `at` is rejected outright on the boolean/stack ops
  (`union`, `cut`, `intersect`).
  """

  @max_ops 200
  @max_code_bytes 20_000
  @max_coord 1.0e5
  @min_positive 1.0e-6

  @stack_ops ~w(union cut intersect)
  @shape_ops ~w(box cylinder sphere prism cone torus)
  @profile_ops ~w(polygon polyline)
  @pattern_ops ~w(pattern_linear pattern_circular)
  @max_points 512
  @max_pattern_instances 1000
  @max_selectors 8
  @known_ops @shape_ops ++ @stack_ops ++ @profile_ops ++ @pattern_ops ++ ~w(translate fillet_all chamfer_all fillet chamfer extrude rotate revolve loft mirror scale shell sweep helix circle text)

  @spec validate(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def validate(code) when is_binary(code) do
    if byte_size(code) > @max_code_bytes do
      {:error, "ocex: program exceeds #{@max_code_bytes} bytes"}
    else
      with {:ok, %{"ops" => ops}} <- decode(code),
           {:ok, ops} <- check_list(ops),
           :ok <- check_each(ops),
           :ok <- pattern_budget(ops) do
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

  # Program-level cap: each pattern op builds `count` copies of its input, so
  # a chain of large patterns could explode the kernel — cap the sum.
  defp pattern_budget(ops) do
    total =
      Enum.reduce(ops, 0, fn
        %{"op" => name, "count" => count}, acc when name in @pattern_ops and is_integer(count) ->
          acc + count

        _op, acc ->
          acc
      end)

    if total > @max_pattern_instances,
      do: {:error, "ocex: patterns would build more than #{@max_pattern_instances} instances"},
      else: :ok
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

  defp check_params("box", op, i) do
    with :ok <-
           vec3(op, "size", i, &positive_num?/1, "positive numbers of millimetres below #{@max_coord}"),
         do: optional_at(op, i)
  end

  defp check_params("cylinder", op, i) do
    with :ok <- positive(op, "r", i),
         :ok <- positive(op, "h", i),
         do: optional_at(op, i)
  end

  defp check_params("sphere", op, i) do
    with :ok <- positive(op, "r", i), do: optional_at(op, i)
  end

  defp check_params("translate", op, i), do: vec3(op, "delta", i, &coord?/1, "finite numbers")

  defp check_params("polyline", op, i) do
    with :ok <- points(op, "pts", i),
         :ok <- optional_bool(op, "close", i),
         do: optional_at(op, i)
  end

  defp check_params("polygon", op, i) do
    with :ok <- ngon_n(op, i),
         :ok <- positive(op, "r", i),
         :ok <- optional_number(op, "rot", i),
         do: optional_at(op, i)
  end

  defp check_params("pattern_linear", op, i) do
    with :ok <- pattern_count(op, i), do: nonzero_vec3(op, "delta", i)
  end

  defp check_params("pattern_circular", op, i) do
    with :ok <- pattern_count(op, i),
         :ok <- optional_nonzero_vec3(op, "axis", i),
         :ok <- optional_degrees(op, i) do
      optional_at(op, i)
    end
  end

  defp check_params("revolve", op, i) do
    with :ok <- nonzero_vec3(op, "axis", i),
         :ok <- optional_degrees(op, i) do
      optional_at(op, i)
    end
  end

  defp check_params("loft", op, i), do: sections(op, i)

  defp check_params("mirror", op, i) do
    with :ok <- nonzero_vec3(op, "normal", i), do: optional_at(op, i)
  end

  defp check_params("scale", op, i), do: positive(op, "factor", i)

  defp check_params("helix", op, i) do
    with :ok <- positive(op, "r", i),
         :ok <- positive(op, "pitch", i),
         :ok <- turns(op, i) do
      optional_at(op, i)
    end
  end

  defp check_params("cone", op, i) do
    with :ok <- positive(op, "r1", i),
         :ok <- nonneg(op, "r2", i),
         :ok <- positive(op, "h", i) do
      optional_at(op, i)
    end
  end

  defp check_params("torus", op, i) do
    with :ok <- positive(op, "R", i),
         :ok <- positive(op, "r", i) do
      if op["r"] < op["R"] do
        optional_at(op, i)
      else
        {:error, "ocex: op #{i}: \"r\" must be smaller than \"R\""}
      end
    end
  end

  # `dir` is optional (prompt: default +z); the interpreter defaults it.
  defp check_params("extrude", op, i) do
    with :ok <- positive(op, "h", i), do: optional_nonzero_vec3(op, "dir", i)
  end

  defp check_params("rotate", op, i) do
    case nonzero_vec3(op, "axis", i) do
      :ok ->
        case Map.fetch(op, "degrees") do
          {:ok, degrees} ->
            if is_number(degrees) and finite?(degrees) and abs(degrees) <= 3600,
              do: :ok,
              else: {:error, "ocex: op #{i}: \"degrees\" must be a finite number within ±3600"}

          :error ->
            {:error, "ocex: op #{i}: missing \"degrees\""}
        end

      error ->
        error
    end
  end

  defp check_params("fillet_all", op, i), do: positive(op, "r", i)

  defp check_params("chamfer_all", op, i), do: positive(op, "d", i)

  defp check_params("fillet", op, i) do
    with :ok <- positive(op, "r", i), do: require_selector(op, i)
  end

  defp check_params("chamfer", op, i) do
    with :ok <- positive(op, "d", i), do: require_selector(op, i)
  end

  defp check_params("circle", op, i) do
    with :ok <- positive(op, "r", i), do: optional_at(op, i)
  end

  defp check_params("text", op, i) do
    with :ok <- text_s(op, i),
         :ok <- text_size(op, i) do
      optional_at(op, i)
    end
  end

  defp check_params("shell", op, i) do
    with :ok <- positive(op, "t", i), do: require_open(op, i)
  end

  defp check_params("prism", op, i) do
    with :ok <- sides(op, i),
         :ok <- positive(op, "r", i),
         :ok <- positive(op, "h", i),
         :ok <- optional_number(op, "rot", i) do
      optional_at(op, i)
    end
  end

  defp check_params(name, op, i) when name in @stack_ops do
    case Map.fetch(op, "at") do
      :error -> :ok
      {:ok, _} -> {:error, "ocex: op #{i}: \"#{name}\" takes no \"at\""}
    end
  end

  # `sweep` takes no params; the remaining ops have no extra constraints.
  defp check_params(_name, _op, _i), do: :ok

  defp require_selector(op, i) do
    case Map.fetch(op, "on") do
      {:ok, selector} -> validate_selector(selector, i)
      :error -> {:error, "ocex: op #{i}: missing \"on\""}
    end
  end

  @max_text_chars 256

  defp text_s(op, i) do
    case Map.fetch(op, "s") do
      {:ok, s} when is_binary(s) ->
        cond do
          String.length(s) > @max_text_chars ->
            {:error, "ocex: op #{i}: \"s\" must be at most #{@max_text_chars} characters"}

          String.trim(s) == "" ->
            {:error, "ocex: op #{i}: \"s\" must be a non-empty string"}

          true ->
            :ok
        end

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"s\" must be a non-empty string"}

      :error ->
        {:error, "ocex: op #{i}: missing \"s\""}
    end
  end

  defp text_size(op, i) do
    case Map.fetch(op, "size") do
      {:ok, size} ->
        if is_number(size) and finite?(size) and size >= @min_positive and size <= 1000,
          do: :ok,
          else: {:error, "ocex: op #{i}: \"size\" must be a positive number up to 1000"}

      :error ->
        {:error, "ocex: op #{i}: missing \"size\""}
    end
  end

  defp sides(op, i) do
    case Map.fetch(op, "n") do
      {:ok, n} when is_integer(n) and n >= 3 and n <= 64 ->
        :ok

      {:ok, n} when is_integer(n) ->
        {:error, "ocex: op #{i}: \"n\" must be between 3 and 64, got #{n}"}

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"n\" must be an integer (number of sides)"}

      :error ->
        {:error, "ocex: op #{i}: missing \"n\""}
    end
  end

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

  defp ngon_n(op, i) do
    case Map.fetch(op, "n") do
      {:ok, n} when is_integer(n) and n >= 3 and n <= 120 ->
        :ok

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"n\" must be an integer from 3 to 120"}

      :error ->
        {:error, "ocex: op #{i}: missing \"n\""}
    end
  end

  defp optional_number(op, key, i) do
    case Map.fetch(op, key) do
      {:ok, value} ->
        if is_number(value) and finite?(value),
          do: :ok,
          else: {:error, "ocex: op #{i}: \"#{key}\" must be a finite number"}

      :error ->
        :ok
    end
  end

  defp nonzero_vec3(op, key, i) do
    case vec3(op, key, i, &coord?/1, "finite numbers") do
      :ok ->
        [dx, dy, dz] = op[key]

        if dx == 0 and dy == 0 and dz == 0,
          do: {:error, "ocex: op #{i}: \"#{key}\" must not be the zero vector"},
          else: :ok

      error ->
        error
    end
  end

  # Validates `op[key]` as a list of 2..@max_points [x, y, z] points with no
  # consecutive duplicates.
  defp points(op, key, i) do
    case Map.fetch(op, key) do
      {:ok, pts} when is_list(pts) ->
        cond do
          length(pts) < 2 ->
            {:error, "ocex: op #{i}: \"#{key}\" must contain at least 2 points"}

          length(pts) > @max_points ->
            {:error, "ocex: op #{i}: \"#{key}\" must contain at most #{@max_points} points"}

          true ->
            walk_points(pts, nil, key, i)
        end

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"#{key}\" must be an array of [x, y, z] points"}

      :error ->
        {:error, "ocex: op #{i}: missing \"#{key}\""}
    end
  end

  defp walk_points([], _prev, _key, _i), do: :ok

  defp walk_points([pt | rest], prev, key, i) do
    cond do
      not point3?(pt) ->
        {:error, "ocex: op #{i}: \"#{key}\" entries must be [x, y, z] arrays of finite numbers"}

      pt == prev ->
        {:error, "ocex: op #{i}: \"#{key}\" must not contain consecutive duplicate points"}

      true ->
        walk_points(rest, pt, key, i)
    end
  end

  defp point3?([x, y, z]), do: coord?(x) and coord?(y) and coord?(z)
  defp point3?(_other), do: false

  defp optional_bool(op, key, i) do
    case Map.fetch(op, key) do
      {:ok, value} when is_boolean(value) ->
        :ok

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"#{key}\" must be a boolean"}

      :error ->
        :ok
    end
  end

  defp pattern_count(op, i) do
    case Map.fetch(op, "count") do
      {:ok, n} when is_integer(n) and n >= 2 and n <= 200 ->
        :ok

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"count\" must be an integer from 2 to 200"}

      :error ->
        {:error, "ocex: op #{i}: missing \"count\""}
    end
  end

  defp sections(op, i) do
    case Map.fetch(op, "sections") do
      {:ok, n} when is_integer(n) and n >= 2 and n <= 50 ->
        :ok

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"sections\" must be an integer from 2 to 50"}

      :error ->
        {:error, "ocex: op #{i}: missing \"sections\""}
    end
  end

  # Zero allowed (cone r2 = apex); kernel rejects r1 == r2 at runtime.
  defp nonneg(op, key, i) do
    case Map.fetch(op, key) do
      {:ok, value} ->
        if is_number(value) and finite?(value) and value >= 0,
          do: :ok,
          else: {:error, "ocex: op #{i}: \"#{key}\" must be a number >= 0"}

      :error ->
        {:error, "ocex: op #{i}: missing \"#{key}\""}
    end
  end

  defp turns(op, i) do
    case Map.fetch(op, "turns") do
      {:ok, t} ->
        if is_number(t) and finite?(t) and t > 0 and t <= 25 do
          :ok
        else
          {:error, "ocex: op #{i}: \"turns\" must be a number greater than 0 and at most 25"}
        end

      :error ->
        {:error, "ocex: op #{i}: missing \"turns\""}
    end
  end

  defp optional_nonzero_vec3(op, key, i) do
    case Map.fetch(op, key) do
      :error -> :ok
      {:ok, _} -> nonzero_vec3(op, key, i)
    end
  end

  defp optional_degrees(op, i) do
    case Map.fetch(op, "degrees") do
      {:ok, degrees} ->
        if is_number(degrees) and finite?(degrees) and degrees >= 1 and degrees <= 360 do
          :ok
        else
          {:error, "ocex: op #{i}: \"degrees\" must be a number from 1 to 360"}
        end

      :error ->
        :ok
    end
  end

  # Validates the optional "at" placement as a finite vec3; `:ok` when absent.
  defp optional_at(op, i) do
    case Map.fetch(op, "at") do
      :error -> :ok
      {:ok, _} -> vec3(op, "at", i, &coord?/1, "finite numbers")
    end
  end

  # The kernel's shell demands at least one opening (no closed hollow).
  defp require_open(op, i) do
    case Map.fetch(op, "open") do
      {:ok, selectors} when is_list(selectors) ->
        cond do
          length(selectors) < 1 ->
            {:error, "ocex: op #{i}: \"open\" must contain at least one selector"}

          length(selectors) > @max_selectors ->
            {:error, "ocex: op #{i}: \"open\" must contain at most #{@max_selectors} selectors"}

          true ->
            selectors
            |> Enum.reduce_while(:ok, fn selector, :ok ->
              case validate_selector(selector, i) do
                :ok -> {:cont, :ok}
                {:error, _msg} = error -> {:halt, error}
              end
            end)
        end

      {:ok, _other} ->
        {:error, "ocex: op #{i}: \"open\" must be an array of face selectors"}

      :error ->
        {:error, "ocex: op #{i}: missing \"open\""}
    end
  end

  # A face selector uses EXACTLY one form:
  #   {"normal": [nx,ny,nz], "through": [px,py,pz]} — planar faces parallel to
  #                                                 the normal, plane through p
  #   {"perpendicular": [ax,ay,az]}                — planar faces whose normal
  #                                                 is perpendicular to the axis
  defp validate_selector(selector, i) when is_map(selector) do
    perm? = Map.has_key?(selector, "perpendicular")
    norm? = Map.has_key?(selector, "normal")
    through? = Map.has_key?(selector, "through")

    cond do
      perm? and (norm? or through?) ->
        {:error,
         "ocex: op #{i}: selector must use either \"perpendicular\" or \"normal\"+\"through\", not both"}

      perm? ->
        nonzero_vec3(selector, "perpendicular", i)

      norm? and through? ->
        with :ok <- nonzero_vec3(selector, "normal", i) do
          vec3(selector, "through", i, &coord?/1, "finite numbers")
        end

      true ->
        {:error,
         "ocex: op #{i}: selector must be an object with either \"perpendicular\" or \"normal\" and \"through\""}
    end
  end

  defp validate_selector(_other, i) do
    {:error,
     "ocex: op #{i}: selector must be an object with either \"perpendicular\" or \"normal\" and \"through\""}
  end

  defp coord?(value) when is_number(value), do: finite?(value) and abs(value) <= @max_coord
  defp coord?(_other), do: false

  defp finite?(value) when is_float(value), do: abs(value) <= Float.max_finite()
  defp finite?(value) when is_integer(value), do: true
end
