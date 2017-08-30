use Mix.Config


config :phoenix, format_encoders: [json: Poison]

config :guardian, Guardian.Phoenix.ControllerTest.Endpoint,
  secret_key_base: "lksdjfl"

config :guardian, Guardian.Phoenix.SocketTest.Impl, []

config :guardian, Guardian.Phoenix.Permissions.BitwiseTest.Impl, []
