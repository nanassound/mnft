defmodule Mnft.Cad.Engines.OpenScad do
  @moduledoc """
  The OpenSCAD engine: shells out to the `openscad` binary over a Port and
  measures the resulting binary STL in pure Elixir (STL parse + GLB preview).

  Mesh-only — OpenSCAD cannot produce STEP, so `artifacts.step` is always nil.
  Implements the `Mnft.Cad.Engine` behaviour; never raises.
  """

  @behaviour Mnft.Cad.Engine

  alias Mnft.Cad.Engines.OpenScad.{Glb, Stl}

  @max_code_bytes 20_000
  @timeout_error "execution exceeded the wall clock and was killed"

  @impl Mnft.Cad.Engine
  def execute(code, owner_id) do
    with :ok <- static_check(code) do
      run(code, owner_id)
    else
      {:error, msg} -> fail(:static_check, msg)
    end
  rescue
    e -> fail(:exec, "runner failure: #{Exception.format(:error, e)}")
  catch
    kind, value -> fail(:exec, "runner failure: #{kind} #{inspect(value)}")
  end

  defp run(code, owner_id) do
    cfg = Mnft.Cad.Config.get(:openscad, [])
    model_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    model_dir =
      Path.absname(Path.join([Mnft.Cad.Config.get(:models_dir), owner_id, model_id]))

    with :ok <- mkdir(model_dir),
         scad = Path.join(model_dir, "part.scad"),
         :ok <- File.write(scad, code) |> wrap("cannot write part.scad") do
      {ms, result} = :timer.tc(fn -> run_openscad(cfg, model_dir) end)

      case result do
        :ok ->
          finish(model_dir, model_id, div(ms, 1000))

        {:error, reason} ->
          %{
            ok: false,
            stage: :exec,
            error: reason,
            artifacts: nil,
            mesh: nil,
            exec_ms: div(ms, 1000)
          }
      end
    end
  end

  @impl Mnft.Cad.Engine
  def healthy? do
    bin = Mnft.Cad.Config.get(:openscad, [])[:bin] || "openscad"
    System.find_executable(bin) != nil
  end

  # --- static gate -------------------------------------------------------------

  defp static_check(code) do
    cond do
      byte_size(code) > @max_code_bytes ->
        {:error, "openscad: source exceeds #{@max_code_bytes} bytes"}

      Regex.match?(~r/\bimport\s*\(/, code) ->
        {:error, "openscad: import() is not allowed"}

      Regex.match?(~r/\bsurface\s*\(/, code) ->
        {:error, "openscad: surface() is not allowed"}

      Regex.match?(~r/^\s*(include|use)\s*</m, code) ->
        {:error, "openscad: include/use of external files is not allowed"}

      true ->
        :ok
    end
  end

  # --- Port run ----------------------------------------------------------------

  defp run_openscad(cfg, model_dir) do
    bin = cfg[:bin] || "openscad"

    args = [
      "-o",
      "model.stl",
      "--export-format",
      "binstl",
      "--hardwarnings",
      "--backend",
      "manifold",
      "part.scad"
    ]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.find_executable(bin) || bin)},
        [:binary, :exit_status, {:args, args}, {:cd, String.to_charlist(model_dir)}]
      )

    timeout_s = cfg[:timeout_s] || cfg[:exec_timeout_s] || 60

    case collect(port, nil, timeout_s * 1000) do
      {:ok, 0} ->
        :ok

      {:ok, status} ->
        {:error, "openscad exited with status #{status}"}

      {:error, :timeout} ->
        Port.close(port)
        {:error, @timeout_error}
    end
  end

  defp collect(port, _status, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  # --- post-run ----------------------------------------------------------------

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create model dir: #{inspect(reason)}"}
    end
  end

  defp wrap(:ok, _msg), do: :ok
  defp wrap({:error, reason}, msg), do: {:error, "#{msg}: #{inspect(reason)}"}

  defp finish(model_dir, model_id, exec_ms) do
    stl_path = Path.join(model_dir, "model.stl")

    case Stl.parse(stl_path) do
      {:ok, mesh} ->
        glb_path = Path.join(model_dir, "model.glb")

        # GLB is a coarse preview only: best-effort, nil on failure.
        glb =
          case Glb.write(stl_path, glb_path) do
            :ok -> glb_path
            _ -> nil
          end

        %{
          ok: true,
          stage: :exec,
          error: nil,
          artifacts: %{model_id: model_id, stl: stl_path, step: nil, glb: glb},
          mesh: mesh,
          exec_ms: exec_ms
        }

      {:error, reason} ->
        fail(:exec, "openscad: failed to parse STL output (#{inspect(reason)})")
    end
  end

  defp fail(stage, error) do
    %{ok: false, stage: stage, error: error, artifacts: nil, mesh: nil, exec_ms: 0}
  end
end
