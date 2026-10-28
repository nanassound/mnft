defmodule MnftCadWeb.ModelURL do
  @moduledoc """
  Artifact URL helpers. Model files are served as `/m/<model_id>/<file>`,
  with the prefix configurable via `config :mnft_cad_web, :artifact_url_prefix`
  (default `"/m"`) so a host can front them with a CDN or object store.
  """

  @spec prefix() :: String.t()
  def prefix do
    Application.get_env(:mnft_cad_web, :artifact_url_prefix, "/m")
  end

  @spec file(model_id :: String.t(), filename :: String.t()) :: String.t()
  def file(model_id, filename) do
    Path.join([prefix(), model_id, filename])
  end

  @spec stl(model_id :: String.t()) :: String.t()
  def stl(model_id), do: file(model_id, "model.stl")

  @spec step(model_id :: String.t()) :: String.t()
  def step(model_id), do: file(model_id, "model.step")

  @spec glb(model_id :: String.t()) :: String.t()
  def glb(model_id), do: file(model_id, "model.glb")
end
