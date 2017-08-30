defmodule Guardian.Token.JwtTest do
  use ExUnit.CaseTemplate

  defmodule Impl do
    use Guardian, otp_app: :guardian,
                  token_module: Guardian.Token.Jwt,
                  issuer: "MyApp",
                  verify_issuer: true,
                  secret_key: "foo-de-fafa",
                  allowed_algos: ["HS512", "ES512"],
                  ttl: {4, :weeks},
                  token_ttl: %{
                    "access" => {1, :day},
                    "refresh" => {2, :weeks},
                  }

    def subject_for_token(%{id: id}, _claims), do: {:ok, "User:#{id}"}
    def resource_from_claims(%{"sub" => "User:" <> sub}), do: {:ok, %{id: sub}}

    def the_secret_yo, do: config(:secret_key)
    def the_secret_yo(val), do: val

    def verify_claims(claims, opts) do
      if Keyword.get(opts, :fail_owner_verify_claims) do
        {:error, Keyword.get(opts, :fail_owner_verify_claims)}
      else
        {:ok, claims}
      end
    end

    def build_claims(claims, _opts) do
      Map.put(claims, "from_owner", "here")
    end
  end

  setup do
    claims = %{
      "jti" => UUID.uuid4(),
      "aud" => "MyApp",
      "typ" => "access",
      "exp" => Guardian.timestamp + 10_000,
      "iat" => Guardian.timestamp,
      "iss" => "MyApp",
      "sub" => "User:1",
      "something_else" => "foo"
    }

    algo = hd(__MODULE__.Impl.config(:allowed_algos))
    secret = __MODULE__.Impl.config(:secret_key)

    jose_jws = %{"alg" => algo}
    jose_jwk = %{"kty" => "oct", "k" => :base64url.encode(secret)}

    {_, jwt} = jose_jwk
                  |> JOSE.JWT.sign(jose_jws, claims)
                  |> JOSE.JWS.compact

    es512_jose_jwk = JOSE.JWK.generate_key({:ec, :secp521r1})
    es512_jose_jws = JOSE.JWS.from_map(%{"alg" => "ES512"})
    es512_jose_jwt = es512_jose_jwk
      |> JOSE.JWT.sign(es512_jose_jws, claims)
      |> JOSE.JWS.compact
      |> elem(1)

    {
      :ok,
      %{
        claims: claims,
        jwt: jwt,
        jose_jws: jose_jws,
        jose_jwk: jose_jwk,
        es512: %{
          jwk: es512_jose_jwk,
          jws: es512_jose_jws,
          jwt: es512_jose_jwt
        },
        impl: __MODULE__.Impl,
        token_mod: Guardian.Token.Jwt,
      }
    }
  end
end

defmodule Guardian.Token.JwtTest.Peek do
  use Guardian.Token.JwtTest, async: true

  test "with a nil token", %{token_mod: mod} do
    assert apply(mod, :peek, [nil]) == nil
  end

  test "with a valid token", %{token_mod: mod, jwt: jwt, claims: claims} do
    result = apply(mod, :peek, [jwt])
    assert result == %{
      headers: %{"typ" => "JWT"},
      claims: claims
    }
  end
end

defmodule Guardian.Token.JwtTest.TokenId do
  use ExUnit.Case, async: true

  test "it generates a UUID" do
    token1 = Guardian.Token.Jwt.token_id
    token2 = Guardian.Token.Jwt.token_id
    assert token1
    assert token2
    refute token1 == token2
  end
end

defmodule Guardian.Token.JwtTest.CreateToken do
  use Guardian.Token.JwtTest, async: true
  alias Guardian.Token.Jwt

  test "create a token plain token", ctx do
    secret =
      :secret_key
      |> ctx.impl.config()
      |> JOSE.JWK.from_oct()

    {:ok, token} = Jwt.create_token(ctx.impl, ctx.claims)

    {true, jwt, _} = JOSE.JWT.verify_strict(
      secret,
      ["HS512"],
      token
    )

    assert jwt.fields == ctx.claims
  end

  test "create a token with a custom secret %JOSE.JWK{} struct", ctx do
    secret = ctx.es512.jwk
    {:ok, token} = Jwt.create_token(
      ctx.impl,
      ctx.claims,
      secret: secret,
      allowed_algos: ["ES512"],
    )

    {true, jwt, _} = JOSE.JWT.verify_strict(
      secret,
      ["ES512"],
      token
    )

    assert jwt.fields == ctx.claims

    {:error, _reason} = JOSE.JWT.verify_strict(
      ctx.impl.config(:secret_key),
      ["HS512"],
      token
    )
  end

  test "create a token with a custom secret map", ctx do
    secret = ctx.es512.jwk |> JOSE.JWK.to_map |> elem(1)
    {:ok, token} = Jwt.create_token(
      ctx.impl,
      ctx.claims,
      secret: secret,
      allowed_algos: ["ES512"]
    )

    {true, jwt, _} = JOSE.JWT.verify_strict(
      secret,
      ["ES512"],
      token
    )

    assert jwt.fields == ctx.claims
  end

  test "it creates a token with an {m, f}", ctx do
    secret = {ctx.impl, :the_secret_yo}

    {:ok, token} = Jwt.create_token(ctx.impl, ctx.claims, secret: secret)

    {true, jwt, _} = JOSE.JWT.verify_strict(
      JOSE.JWK.from_oct(ctx.impl.the_secret_yo),
      ["HS512"],
      token
    )

    assert jwt.fields == ctx.claims
  end

  test "it creates a token with an {m, f, a}", ctx do
    the_secret = ctx.impl.config(:secret_key)
    secret = {ctx.impl, :the_secret_yo, [the_secret]}

    {:ok, token} = Jwt.create_token(ctx.impl, ctx.claims, secret: secret)

    {true, jwt, _} = JOSE.JWT.verify_strict(
      JOSE.JWK.from_oct(the_secret),
      ["HS512"],
      token
    )

    assert jwt.fields == ctx.claims
  end

  test "it creates a token with an secret function", ctx do
    the_secret = ctx.impl.config(:secret_key)
    secret = fn -> the_secret end

    {:ok, token} = Jwt.create_token(ctx.impl, ctx.claims, secret: secret)

    {true, jwt, _} = JOSE.JWT.verify_strict(
      JOSE.JWK.from_oct(the_secret),
      ["HS512"],
      token
    )

    assert jwt.fields == ctx.claims
  end
end

defmodule Guardian.Token.JwtTest.DecodeToken do
  use Guardian.Token.JwtTest, async: true
  alias Guardian.Token.Jwt

  test "can verify a plain token", ctx do
    {:ok, claims} = Jwt.decode_token(ctx.impl, ctx.jwt)
    assert claims == ctx.claims
  end

  test "does not verify with a bad secret", ctx do
    {:error, :invalid_token} = Jwt.decode_token(ctx.impl, ctx.jwt, secret: "no")
  end

  test "it decodes the jwt with custom secret %JOSE.JWK{} struct", ctx do
    secret = ctx.es512.jwk
    result = Jwt.decode_token(ctx.impl, ctx.es512.jwt, secret: secret)
    assert {:ok, ctx.claims} == result
  end

  test "it decodes the jwt with a module function", ctx do
    secret = {ctx.impl, :the_secret_yo}
    result = Jwt.decode_token(ctx.impl, ctx.jwt, secret: secret)
    assert {:ok, ctx.claims} == result
  end

  test "it decodes the jwt with an {m, f, a}", ctx do
    the_secret = ctx.impl.config(:secret_key)
    secret = {ctx.impl, :the_secret_yo, [the_secret]}
    result = Jwt.decode_token(ctx.impl, ctx.jwt, secret: secret)
    assert {:ok, ctx.claims} == result
  end

  test "it decodes the jwt with a :secret function", ctx do
    the_secret = ctx.impl.config(:secret_key)
    secret = fn -> the_secret end

    result = Jwt.decode_token(ctx.impl, ctx.jwt, secret: secret)
    assert {:ok, ctx.claims} == result
  end
end

defmodule Guardian.Token.JwtTest.BuildClaims do
  use Guardian.Token.JwtTest, async: true
  alias Guardian.Token.Jwt

  @resource %{id: "bobby"}

  setup %{impl: impl} do
    {:ok, sub} = impl.subject_for_token(@resource, %{})
    {:ok, %{sub: sub}}
  end

  test "it adds some fields", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub
    )

    assert result["jti"]
    assert result["iat"]
    assert result["iss"] == ctx.impl.config(:issuer)
    assert result["aud"] == ctx.impl.config(:issuer)
    assert result["typ"] == ctx.impl.default_token_type
    assert result["sub"] == ctx.sub
  end

  test "it keeps other fields that have been added", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{my: "claim"}
    )

    assert result["my"] == "claim"
  end

  test "sets the ttl when specified in seconds", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {5, :seconds}]
    )
    diff = (Guardian.timestamp + 5) - result["exp"]
    assert diff <= 1
  end

  test "sets the ttl when specified in minutes", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :minute}]
    )
    diff = (Guardian.timestamp + 60) - result["exp"]
    assert diff <= 1

    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :minutes}]
    )
    diff = (Guardian.timestamp + 60) - result["exp"]
    assert diff <= 1
  end

  test "sets the ttl when specified in hours", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :hour}]
    )
    diff = (Guardian.timestamp + 60 * 60) - result["exp"]
    assert diff <= 1

    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :hours}]
    )
    diff = (Guardian.timestamp + 60 * 60) - result["exp"]
    assert diff <= 1
  end

  test "sets the ttl when specified in days", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :day}]
    )
    diff = (Guardian.timestamp + 24 * 60 * 60) - result["exp"]
    assert diff <= 1

    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :days}]
    )
    diff = (Guardian.timestamp + 24 * 60 * 60) - result["exp"]
    assert diff <= 1
  end

  test "sets the ttl when specified in weeks", ctx do
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :week}]
    )
    diff = (Guardian.timestamp + 7 * 24 * 60 * 60) - result["exp"]
    assert diff <= 1

    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [ttl: {1, :weeks}]
    )
    diff = (Guardian.timestamp + 7 * 24 * 60 * 60) - result["exp"]
    assert diff <= 1
  end

  test "keeps the expiry when specified", ctx do
    time = Guardian.timestamp + 26
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{exp: time}
    )
    assert result["exp"] == time
  end

  test "sets to the default for the token type", ctx do
    expected = Guardian.timestamp + 24 * 60 * 60
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{}
    )
    diff = (expected) - result["exp"]
    assert diff <= 1

    expected = Guardian.timestamp + 2 * 7 * 24 * 60 * 60
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [token_type: "refresh"]
    )
    diff = (expected) - result["exp"]
    assert diff <= 1
    assert result["typ"] == "refresh"

    expected = Guardian.timestamp + 4 * 7 * 24 * 60 * 60
    result = Jwt.build_claims(
      ctx.impl,
      @resource,
      ctx.sub,
      %{},
      [token_type: "other"]
    )
    diff = (expected) - result["exp"]
    assert result["typ"] == "other"
    assert diff <= 1
  end
end

defmodule Guardian.Token.JwtTest.VerifyClaims do
  use Guardian.Token.JwtTest, async: true
  alias Guardian.Token.Jwt

  setup do
    claims = %{
      "iat": Guardian.timestamp,
      "nbf": Guardian.timestamp - 1,
      "exp": Guardian.timestamp + 5,
    }

    {:ok, %{claims: claims}}
  end

  test "it verifies using the owner module", ctx do
    result = Jwt.verify_claims(ctx.impl, ctx.claims, [fail_owner_verify_claims: :boo])
    assert result == {:error, :boo}
  end

  test "it is invalid when exp is too early", ctx do
    claims = Map.put(ctx.claims, "exp", Guardian.timestamp - 1)
    result = Jwt.verify_claims(ctx.impl, claims, [])
    assert result == {:error, :token_expired}
  end

  test "it is invalid when nbf is too late", ctx do
    claims = Map.put(ctx.claims, "nbf", Guardian.timestamp + 5)
    result = Jwt.verify_claims(ctx.impl, claims, [])
    assert result == {:error, :token_not_yet_valid}
  end

  test "it is invalid when the issuer is not correct", ctx do
    claims = Map.put(ctx.claims, "iss", "someone-else")
    result = Jwt.verify_claims(ctx.impl, claims, [])
    assert result == {:error, :invalid_issuer}
  end

  test "it is valid when all is good", ctx do
    result = Jwt.verify_claims(ctx.impl, ctx.claims, [])
    assert result == {:ok, ctx.claims}
  end
end

defmodule Guardian.Token.JwtTest.Refresh do
  use Guardian.Token.JwtTest, async: true
  alias Guardian.Token.Jwt

  test "it refreshes the jwt exp", ctx do
    old_token = ctx.jwt
    old_claims = ctx.claims
    {:ok, {^old_token = old_t, ^old_claims = old_c}, {new_t, new_c}} =
      Jwt.refresh(ctx.impl, ctx.jwt, [])

    refute old_t == new_t
    assert new_c["sub"] == old_c["sub"]
    assert new_c["aud"] == old_c["aud"]

    refute new_c["jti"] == old_c["jti"]
    refute new_c["nbf"] == old_c["nbf"]
    refute new_c["exp"] == old_c["exp"]
  end

  test "it allows custom ttl", ctx do
    old_token = ctx.jwt
    old_claims = ctx.claims
    {:ok, {^old_token = old_t, ^old_claims = old_c}, {new_t, new_c}} =
      Jwt.refresh(ctx.impl, ctx.jwt, [ttl: {30, :seconds}])

    refute old_t == new_t

    assert new_c["sub"] == old_c["sub"]
    assert new_c["aud"] == old_c["aud"]

    refute new_c["jti"] == old_c["jti"]
    refute new_c["nbf"] == old_c["nbf"]
    refute new_c["exp"] == old_c["exp"]
    assert new_c["exp"] == new_c["iat"] + 30

    {:ok, {^new_t, ^new_c}, {very_new_t, very_new_c}} =
      Jwt.refresh(ctx.impl, new_t, [ttl: {78, :seconds}])

    refute new_t == very_new_t
    assert very_new_c["exp"] == very_new_c["iat"] + 78
  end
end
