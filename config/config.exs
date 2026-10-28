import Config

config :exmaster,
  # protocol:[host:]port[=label], comma-separated. See README.md.
  listen: "q3:27950,q2:27900,qw:27000",
  max_servers: 16_384,
  max_per_ip: 32,
  max_unknown_tag: 512,
  server_ttl: :timer.minutes(15),
  challenge_ttl: :timer.seconds(5)

if config_env() == :test do
  config :exmaster, listen: ""
  config :logger, level: :warning
end
