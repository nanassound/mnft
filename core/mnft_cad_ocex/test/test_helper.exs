# The cross-kernel test shells out to the real build123d worker; excluded from
# the default run, included with `mix test --include cross_kernel`.
ExUnit.configure(exclude: [:cross_kernel])
ExUnit.start()
