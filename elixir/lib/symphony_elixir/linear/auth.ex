defmodule SymphonyElixir.Linear.Auth do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Config

  @token_endpoint "https://api.linear.app/oauth/token"
  @call_timeout 50_000

  @type authorization :: %{mode: :api_key | :oauth, token: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec prewarm(keyword()) :: :ok | {:error, term()}
  def prewarm(opts \\ []) do
    case authorization(opts) do
      {:ok, _authorization} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec authorization(keyword()) :: {:ok, authorization()} | {:error, term()}
  def authorization(opts \\ []), do: GenServer.call(__MODULE__, {:authorization, opts}, @call_timeout)

  @spec refresh(String.t(), keyword()) :: {:ok, authorization()} | {:error, term()}
  def refresh(failed_token, opts \\ []) when is_binary(failed_token) do
    GenServer.call(__MODULE__, {:refresh, failed_token, opts}, @call_timeout)
  end

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:authorization, opts}, _from, token) do
    case Config.linear_auth() do
      {:ok, {:api_key, api_key}} ->
        {:reply, {:ok, %{mode: :api_key, token: api_key}}, token}

      {:ok, {:client_credentials, _client_id, _client_secret}} when is_binary(token) ->
        {:reply, {:ok, %{mode: :oauth, token: token}}, token}

      {:ok, {:client_credentials, client_id, client_secret}} ->
        exchange_and_reply(client_id, client_secret, opts, token)

      {:error, _reason} = error ->
        {:reply, error, token}
    end
  end

  def handle_call({:refresh, failed_token, opts}, _from, token) do
    case Config.linear_auth() do
      {:ok, {:api_key, api_key}} ->
        {:reply, {:ok, %{mode: :api_key, token: api_key}}, token}

      {:ok, {:client_credentials, _client_id, _client_secret}} when is_binary(token) and token != failed_token ->
        {:reply, {:ok, %{mode: :oauth, token: token}}, token}

      {:ok, {:client_credentials, client_id, client_secret}} ->
        exchange_and_reply(client_id, client_secret, opts, token)

      {:error, _reason} = error ->
        {:reply, error, token}
    end
  end

  def handle_call(:reset, _from, _token), do: {:reply, :ok, nil}

  defp exchange_and_reply(client_id, client_secret, opts, current_token) do
    case exchange(client_id, client_secret, opts) do
      {:ok, token} -> {:reply, {:ok, %{mode: :oauth, token: token}}, token}
      {:error, _reason} = error -> {:reply, error, current_token}
    end
  end

  defp exchange(client_id, client_secret, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.post/2)

    request_opts = [
      form: [
        grant_type: "client_credentials",
        scope: "read,write",
        client_id: client_id,
        client_secret: client_secret
      ],
      connect_options: [timeout: 30_000],
      receive_timeout: 15_000,
      retry: false
    ]

    try do
      case request_fun.(Keyword.get(opts, :token_endpoint, @token_endpoint), request_opts) do
        {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) and token != "" ->
          {:ok, token}

        {:ok, %{status: 200}} ->
          {:error, :invalid_linear_oauth_token_response}

        {:ok, %{status: status}} when is_integer(status) ->
          {:error, {:linear_oauth_token_status, status}}

        {:error, _reason} ->
          {:error, :linear_oauth_token_request_failed}

        _other ->
          {:error, :invalid_linear_oauth_token_response}
      end
    rescue
      _error -> {:error, :linear_oauth_token_request_failed}
    catch
      _kind, _reason -> {:error, :linear_oauth_token_request_failed}
    end
  end
end
