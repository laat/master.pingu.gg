import Config

if listen = System.get_env("EXMASTER_LISTEN") do
  config :exmaster, listen: listen
end

if peers = System.get_env("EXMASTER_PEERS") do
  config :exmaster,
    peers:
      peers
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
end

for {var, key} <- [
      {"EXMASTER_MAX_SERVERS", :max_servers},
      {"EXMASTER_MAX_PER_IP", :max_per_ip},
      {"EXMASTER_MAX_UNKNOWN_TAG", :max_unknown_tag}
    ],
    value = System.get_env(var) do
  config :exmaster, [{key, String.to_integer(value)}]
end

if level = System.get_env("EXMASTER_LOG_LEVEL") do
  config :logger, level: String.to_existing_atom(level)
end
