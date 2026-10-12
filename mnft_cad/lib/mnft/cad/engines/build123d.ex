defmodule Mnft.Cad.Engines.Build123d do
  @moduledoc """
  The Elixir side of the cad_worker boundary: one Python CLI process per
  execution, spoken to over a Port (stdin: one JSON request line, stdout: one
  JSON reply line). The worker owns rlimits, the guarded harness subprocess,
  and its own hard deadline; this module owns the wall clock.

  Implements the `Mnft.Cad.Engine` behaviour; selected via the `:engine`
  config key (tests use `Mnft.Cad.EngineFake`).
  """

  @behaviour Mnft.Cad.Engine

  @timeout_error "execution exceeded the wall clock and was killed"

  @impl Mnft.Cad.Engine
  @doc """
  Run `code` inside the owner's directory. Returns the CLI's result map with
  atom keys:

      %{ok: boolean, stage: "static_check" | "exec", error: term,
        artifacts: %{model_id: String.t(), stl: path, step: path, glb: path} | nil,
        mesh: %{triangles: term, bbox_mm: term, volume_mm3: term} | nil,
        exec_ms: integer}

  Artifacts are absolute file paths (or nil), scoped
  `<models_dir>/<owner_id>/<model_id>`. Never raises.
  """
  def execute(code, owner_id) do
    cfg = Mnft.Cad.Config.all()

    model_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    # absolute: the worker Port process runs with a different cwd than this app
    model_dir =
      [cfg[:models_dir], owner_id, model_id]
      |> Path.join()
      |> Path.absname()

    File.mkdir_p!(model_dir)

    Mnft.Cad.ExecLimiter.run(fn ->
      port_roundtrip(cfg, %{"code" => code, "model_dir" => model_dir})
    end)
    |> normalize(model_dir)
  rescue
    e ->
      %{
        ok: false,
        stage: :exec,
        error: "runner failure: #{Exception.format(:error, e)}",
        artifacts: nil,
        mesh: nil,
        exec_ms: 0
      }
  catch
    kind, value ->
      %{
        ok: false,
        stage: :exec,
        error: "runner failure: #{kind} #{inspect(value)}",
        artifacts: nil,
        mesh: nil,
        exec_ms: 0
      }
  end

  @impl Mnft.Cad.Engine
  @doc "`true` when the worker answers --health (used by the smoke suite)."
  def healthy? do
    cfg = Mnft.Cad.Config.all()
    port = open_port(cfg, ["--health"])
    reply = collect(port, "", deadline(cfg))

    case reply do
      {:ok, line} ->
        case Jason.decode(line) do
          {:ok, %{"ok" => true}} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # --- Port plumbing -----------------------------------------------------------

  defp port_roundtrip(cfg, request) do
    port = open_port(cfg, [])
    Port.command(port, [Jason.encode!(request), "\n"])

    case collect(port, "", deadline(cfg)) do
      {:ok, line} ->
        Port.close(port)
        Jason.decode(line)

      {:error, :timeout} ->
        # the worker's SIGALRM reaps its own children; closing the port here
        # ends our side of a wedged run
        Port.close(port)
        {:error, @timeout_error}

      {:error, :exit} ->
        {:error, "worker process exited before replying"}
    end
  end

  defp open_port(cfg, extra_args) do
    Port.open(
      {:spawn_executable, String.to_charlist(cfg[:worker_python])},
      [
        :binary,
        :use_stdio,
        :exit_status,
        {:args, ["-m", "cad_worker.cli" | extra_args]},
        {:cd, String.to_charlist(cfg[:worker_cwd])}
      ]
    )
  end

  defp deadline(cfg), do: ((cfg[:exec_timeout_s] || 60) + 5) * 1000

  # Accumulate binary output until the first newline (the reply is one line)
  # or the deadline passes. Data after the newline (there is none by contract)
  # is ignored.
  defp collect(port, buffer, deadline_ms) do
    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data

        case String.split(buffer, "\n", parts: 2) do
          [line, _rest] -> {:ok, String.trim(line)}
          _ -> collect(port, buffer, deadline_ms)
        end

      {^port, {:exit_status, _status}} ->
        {:error, :exit}
    after
      deadline_ms ->
        {:error, :timeout}
    end
  end

  defp normalize({:ok, %{"ok" => true} = result}, model_dir) do
    # PoC guard: a worker that claims success without exports on OUR disk is a failure
    stl = Path.join(model_dir, "model.stl")
    step = Path.join(model_dir, "model.step")

    if File.exists?(stl) and File.exists?(step) do
      artifacts =
        case result["artifacts"] do
          nil ->
            nil

          art ->
            file = fn name ->
              if art[name], do: Path.join(model_dir, art[name])
            end

            %{
              model_id: art["model_id"],
              stl: file.("stl"),
              step: file.("step"),
              glb: file.("glb")
            }
        end

      %{
        ok: true,
        stage: String.to_existing_atom(result["stage"] || "exec"),
        error: result["error"],
        artifacts: artifacts,
        mesh: result["mesh"],
        exec_ms: result["exec_ms"] || 0
      }
    else
      %{
        ok: false,
        stage: :exec,
        error: "harness reported ok but exports are missing",
        artifacts: nil,
        mesh: nil,
        exec_ms: result["exec_ms"] || 0
      }
    end
  end

  defp normalize({:ok, result}, _model_dir) do
    %{
      ok: false,
      stage: String.to_existing_atom(result["stage"] || "exec"),
      error: result["error"],
      artifacts: nil,
      mesh: nil,
      exec_ms: result["exec_ms"] || 0
    }
  end

  defp normalize({:error, reason}, _model_dir) do
    %{ok: false, stage: :exec, error: reason, artifacts: nil, mesh: nil, exec_ms: 0}
  end
end
