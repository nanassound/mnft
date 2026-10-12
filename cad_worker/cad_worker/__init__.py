"""cad_worker: guarded execution of LLM-generated build123d code.

Guarded execution harness, ported from the original Python PoC. That prototype
is gone; this package is a standalone CLI spoken to by the Elixir web tier over
a Port (stdin: one JSON request line, stdout: one JSON reply line).
"""
