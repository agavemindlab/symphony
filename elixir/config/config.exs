import Config

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../../workflows/symphony/WORKFLOW.md", __DIR__),
    # Keep test-run engine logs out of the production log/symphony.log*
    # rotation (test fixtures were interleaving with live-instance logs).
    log_file: Path.join(System.tmp_dir!(), "symphony-elixir-test/symphony.log")
end

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
