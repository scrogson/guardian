defmodule Guardian.Phoenix.SocketTest.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :guardian
end

defmodule Guardian.Phoenix.SocketTest.Impl do
  @moduledoc false
  use Guardian, otp_app: :guardian,
                issuer: "Me",
                secret_key: "some-secret"

  def subject_for_token(%{id: id}, _claims), do: {:ok, to_string(id)}
  def resource_from_claims(%{"sub" => id}), do: {:ok, %{id: id}}
end

defmodule Guardian.Phoenix.SocketTest.MySocket do
  @moduledoc false
  use Phoenix.Socket
  use Guardian.Phoenix.Socket, module: Guardian.Phoenix.SocketTest.Impl

  def connect(_params, _socket), do: :error

  def id(_), do: UUID.uuid4()
end
