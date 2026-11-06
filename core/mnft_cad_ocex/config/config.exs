import Config

# The pack carries no dev/prod config; tests wire tmp dirs and the worker paths.
if Mix.env() == :test do
  import_config "test.exs"
end
