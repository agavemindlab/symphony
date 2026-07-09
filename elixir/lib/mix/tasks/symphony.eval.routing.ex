defmodule Mix.Tasks.Symphony.Eval.Routing do
  use Mix.Task

  @shortdoc "Label active dispatches with the phase artifact their session published"

  @moduledoc """
  Reads the full analytics NDJSON event log (unbounded, unlike the 500-event
  dashboard window), labels each active-state `run_started` dispatch with the
  phase of the first `phase_published` artifact its session produced — the
  ground-truth target phase for Main Flow steps 3–5 routing — and writes the
  routing replay test set:

    * `<output>/cases.jsonl` — one labeled dispatch per line
    * `<output>/labels-report.md` — counts by state × expected phase and the
      unlabeled dispatch count

  Usage:

      mix symphony.eval.routing [--analytics PATH] [--output DIR]

  `--analytics` defaults to the configured analytics event file; `--output`
  defaults to `eval/routing/`. Cases carry internal issue content and must
  stay local (`eval/` is gitignored).
  """

  @requirements ["app.config"]

  alias SymphonyElixir.{Analytics, RoutingLabels}

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [analytics: :string, output: :string])

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    analytics_path = Keyword.get(opts, :analytics, Analytics.file_path())
    output_dir = Keyword.get(opts, :output, "eval/routing")

    case RoutingLabels.read_all_events(analytics_path) do
      {:ok, events} ->
        write_outputs(events, analytics_path, output_dir)

      {:error, reason} ->
        Mix.raise("Unable to read analytics events from #{analytics_path}: #{inspect(reason)}")
    end
  end

  defp write_outputs(events, analytics_path, output_dir) do
    labeled = RoutingLabels.cases(events)
    cases_path = Path.join(output_dir, "cases.jsonl")
    report_path = Path.join(output_dir, "labels-report.md")

    RoutingLabels.write_cases!(cases_path, labeled.cases)
    File.write!(report_path, RoutingLabels.report(labeled))

    Mix.shell().info("Wrote #{length(labeled.cases)} labeled routing case(s) (#{labeled.unlabeled} unlabeled dispatch(es) excluded) from #{analytics_path} to #{cases_path} and #{report_path}")
  end
end
