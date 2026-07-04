defmodule Mix.Tasks.Symphony.Eval.Reviews do
  use Mix.Task

  @shortdoc "Label published phase artifacts with their human dispositions"

  @moduledoc """
  Reads the full analytics NDJSON event log (unbounded, unlike the 500-event
  dashboard window), labels each `phase_published` artifact with its first
  disposition (approve / auto_advanced / request_changes / pending), and
  writes the human-labeled review test set for maestro-reviewer replays:

    * `<output>/cases.jsonl` — one labeled artifact per line
    * `<output>/labels-report.md` — counts by label × phase, the scoreable
      total, and the exclusion caveats

  Usage:

      mix symphony.eval.reviews [--analytics PATH] [--output DIR]

  `--analytics` defaults to the configured analytics event file; `--output`
  defaults to `eval/reviews/`. Cases carry internal issue content and must
  stay local (`eval/` is gitignored).
  """

  @requirements ["app.config"]

  alias SymphonyElixir.{Analytics, ReviewLabels}

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [analytics: :string, output: :string])

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    analytics_path = Keyword.get(opts, :analytics, Analytics.file_path())
    output_dir = Keyword.get(opts, :output, "eval/reviews")

    case ReviewLabels.read_all_events(analytics_path) do
      {:ok, events} ->
        write_outputs(events, analytics_path, output_dir)

      {:error, reason} ->
        Mix.raise("Unable to read analytics events from #{analytics_path}: #{inspect(reason)}")
    end
  end

  defp write_outputs(events, analytics_path, output_dir) do
    cases = ReviewLabels.cases(events)
    cases_path = Path.join(output_dir, "cases.jsonl")
    report_path = Path.join(output_dir, "labels-report.md")

    ReviewLabels.write_cases!(cases_path, cases)
    File.write!(report_path, ReviewLabels.report(cases))

    scoreable = Enum.count(cases, &(&1.label in ["approve", "request_changes"]))
    Mix.shell().info("Wrote #{length(cases)} labeled review case(s) (#{scoreable} scoreable) from #{analytics_path} to #{cases_path} and #{report_path}")
  end
end
