defmodule Mix.Tasks.Symphony.Eval.Maestro do
  use Mix.Task

  @shortdoc "Harvest a local Maestro verdict eval corpus from analytics events"

  @moduledoc """
  Reads the full analytics NDJSON event log (unbounded, unlike the 500-event
  dashboard window), pairs each `maestro_review` event with the first
  subsequent `run_started` dispatch for the same issue (the human verdict),
  and writes a local eval corpus:

    * `<output>/corpus.jsonl` — one review/verdict pair per line, with the
      agreement label as ground truth
    * `<output>/report.md` — agreement rates overall/by-phase/by-recommendation
      and the overridden cases (prompt-improvement candidates)

  Usage:

      mix symphony.eval.maestro [--analytics PATH] [--output DIR]

  `--analytics` defaults to the configured analytics event file; `--output`
  defaults to `eval/maestro/`. Corpora carry internal issue content and must
  stay local (`eval/` is gitignored).
  """

  @requirements ["app.config"]

  alias SymphonyElixir.{Analytics, MaestroEval}

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [analytics: :string, output: :string])

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    analytics_path = Keyword.get(opts, :analytics, Analytics.file_path())
    output_dir = Keyword.get(opts, :output, "eval/maestro")

    case MaestroEval.read_all_events(analytics_path) do
      {:ok, events} ->
        write_outputs(events, analytics_path, output_dir)

      {:error, reason} ->
        Mix.raise("Unable to read analytics events from #{analytics_path}: #{inspect(reason)}")
    end
  end

  defp write_outputs(events, analytics_path, output_dir) do
    pairs = MaestroEval.pairs(events)
    corpus_path = Path.join(output_dir, "corpus.jsonl")
    report_path = Path.join(output_dir, "report.md")

    MaestroEval.write_corpus!(corpus_path, pairs)
    File.write!(report_path, MaestroEval.report(pairs))

    Mix.shell().info("Wrote #{length(pairs)} maestro review pair(s) from #{analytics_path} to #{corpus_path} and #{report_path}")
  end
end
