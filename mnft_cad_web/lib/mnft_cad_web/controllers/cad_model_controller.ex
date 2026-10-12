defmodule MnftCadWeb.CadModelController do
  use MnftCadWeb, :controller

  alias Mnft.Cad

  @content_types %{
    "model.stl" => "model/stl",
    "model.step" => "application/step",
    "model.glb" => "model/gltf-binary"
  }

  @doc """
  Download one artifact. Scoped by the cookie owner: a model id is only
  resolvable for its owner. Invariant: nothing outside model.stl/step/glb is
  ever served.
  """
  def download(conn, %{"model_id" => model_id, "filename" => filename})
      when filename in ["model.stl", "model.step", "model.glb"] do
    owner_id = conn.assigns.owner_id

    with %Cad.Model{} = model <- Cad.get_model(owner_id, model_id),
         path <- Path.join([models_dir(), owner_id, model.id, filename]),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type(Map.fetch!(@content_types, filename))
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> send_file(200, path)
    else
      _nil_or_invalid_or_missing -> send_resp(conn, 404, "Not Found")
    end
  end

  def download(conn, _params), do: send_resp(conn, 404, "Not Found")

  defp models_dir, do: Mnft.Cad.Config.get(:models_dir, "data/models")
end
