defmodule Mix.Tasks.Host.Assets do
  @moduledoc """
  Builds the browser-side kernels from their host packages into `public/`:

    * `cad_worker_web`'s replicad worker (vite `build:worker`) → `public/kernel/`
    * `mnft_cad_web`'s vendored three.js → `public/vendor/three/`

  Idempotent: targets are removed before copying. Run by the `dev`/`cook`
  aliases, never by hand (it shells out to npm and needs `cad_worker_web`'s
  node_modules in place).
  """

  use Mix.Task

  @shortdoc "Build the page-side worker + vendor assets into public/"
  @impl Mix.Task
  def run(_args) do
    {_, 0} =
      System.cmd("npm", ["--prefix", "../cad_worker_web", "run", "build:worker"],
        into: IO.stream(:stdio, :line)
      )

    cp_r("../cad_worker_web/dist-host", "public/kernel")
    cp_r("../mnft_cad_web/assets/vendor/three", "public/vendor/three")

    Mix.shell().info("host assets ready: public/kernel, public/vendor/three")
  end

  defp cp_r(src, dst) do
    unless File.exists?(src) do
      Mix.raise("host asset source missing: #{src} (build it first)")
    end

    File.rm_rf!(dst)
    File.mkdir_p!(Path.dirname(dst))
    File.cp_r!(src, dst)
  end
end
