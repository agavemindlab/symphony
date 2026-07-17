defmodule SymphonyElixir.Linear.Auth do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.Config

  @token_endpoint "https://api.linear.app/oauth/token"
  @call_timeout 50_000

  @type authorization ::
          %{mode: :api_key, token: String.t()}
          | %{mode: :oauth, token: String.t(), version: reference()}

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

  @spec refresh(reference(), keyword()) :: {:ok, authorization()} | {:error, term()}
  def refresh(failed_version, opts \\ []) when is_reference(failed_version) do
    GenServer.call(__MODULE__, {:refresh, failed_version, opts}, @call_timeout)
  end

  @doc false
  @spec reset_for_test() :: :ok
  def reset_for_test, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:authorization, opts}, _from, state) do
    case Config.linear_auth() do
      {:ok, {:api_key, api_key}} ->
        {:reply, {:ok, %{mode: :api_key, token: api_key}}, nil}

      {:ok, {:client_credentials, client_id, client_secret}} ->
        if credential_state?(state, client_id, client_secret) do
          {:reply, {:ok, authorization_from_state(state)}, state}
        else
          exchange_and_reply(client_id, client_secret, opts, state)
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:refresh, failed_version, opts}, _from, state) do
    case Config.linear_auth() do
      {:ok, {:api_key, api_key}} ->
        {:reply, {:ok, %{mode: :api_key, token: api_key}}, nil}

      {:ok, {:client_credentials, client_id, client_secret}} ->
        if credential_state?(state, client_id, client_secret) and state.version != failed_version do
          {:reply, {:ok, authorization_from_state(state)}, state}
        else
          exchange_and_reply(client_id, client_secret, opts, state)
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:reset, _from, _token), do: {:reply, :ok, nil}

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} when is_map(state) -> {:state, :redacted}
      {:message, {:authorization, _opts}} -> {:message, {:authorization, :redacted}}
      {:message, {:refresh, _version, _opts}} -> {:message, {:refresh, :redacted, :redacted}}
      entry -> entry
    end)
  end

  defp exchange_and_reply(client_id, client_secret, opts, current_token) do
    case exchange(client_id, client_secret, opts) do
      {:ok, token} ->
        state = %{
          credentials_hash: credentials_hash(client_id, client_secret),
          token: token,
          version: make_ref()
        }

        {:reply, {:ok, authorization_from_state(state)}, state}

      {:error, _reason} = error ->
        {:reply, error, current_token}
    end
  end

  defp authorization_from_state(state) do
    %{mode: :oauth, token: state.token, version: state.version}
  end

  defp credential_state?(state, client_id, client_secret) do
    is_map(state) and state.credentials_hash == credentials_hash(client_id, client_secret)
  end

  defp credentials_hash(client_id, client_secret) do
    :crypto.hash(:sha256, client_id <> <<0>> <> client_secret)
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
