ExUnit.start()
Application.put_env(:symphony_elixir, :startup_cleanup_progress, false)
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
