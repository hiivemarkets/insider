defmodule Insider.Redaction.CredentialsTest do
  use ExUnit.Case, async: true

  alias Insider.Redaction.Credentials

  # Synthetic, provider-shaped values only. Each is split so the literal
  # never appears whole in this source file.
  @jwt "eyJhbGciOiJIUzI1NiJ9" <>
         "." <> "eyJzdWIiOiJzeW50aGV0aWMifQ" <> "." <> "c2lnbmF0dXJlLXN5bnRo"
  @stripe "sk_" <> "live_" <> "51SyntheticKey0000AbCdEf"
  @aws "AKIA" <> "SYNTHETIC0000000"
  @github "ghp_" <> "Synthetic0123456789abcdefghijKLMN"
  @entropy "q8Zr2LmX7vB4nT1kW9pS3dF6gH0jY5cA"
  @pem "-----BEGIN PRIVATE KEY-----\nMIIEvSyntheticBody\n-----END PRIVATE KEY-----"

  describe "credential keys" do
    test "values under credential keys are masked case-insensitively at every nesting level" do
      value = %{
        "password" => "hunter2-synthetic",
        "Api-Key" => "plain-synthetic",
        "user" => %{
          "AUTHORIZATION" => "anything-synthetic",
          "profile" => [%{"client_secret" => %{"nested" => "deep-synthetic"}}]
        },
        "Set-Cookie" => ["a-synthetic"],
        "private_key" => 42,
        "access_token" => true,
        "source" => "users",
        "token_count_absent" => nil,
        "x_api_key" => ""
      }

      {masked, records} = Credentials.mask(value)

      assert masked["password"] == "[REDACTED:credential_key]"
      assert masked["Api-Key"] == "[REDACTED:credential_key]"
      assert masked["user"]["AUTHORIZATION"] == "[REDACTED:credential_key]"
      assert masked["user"]["profile"] == [%{"client_secret" => "[REDACTED:credential_key]"}]
      assert masked["Set-Cookie"] == "[REDACTED:credential_key]"
      assert masked["private_key"] == "[REDACTED:credential_key]"
      assert masked["access_token"] == "[REDACTED:credential_key]"
      assert masked["source"] == "users"
      # Nothing to hide: absent and empty values stay as they are.
      assert masked["token_count_absent"] == nil
      assert masked["x_api_key"] == ""

      refute inspect(masked) =~ "synthetic"
      refute inspect(records) =~ "synthetic"

      assert record(records, ["key:user", "key:profile", "index:0", "key:client_secret"]) ==
               %{
                 "action" => "mask",
                 "count" => 1,
                 "path" => ["key:user", "key:profile", "index:0", "key:client_secret"],
                 "policy_id" => "insider-credential-masking/v1",
                 "reason" => "credential_key"
               }

      assert records |> Enum.map(& &1["path"]) |> Enum.sort() == [
               ["key:Api-Key"],
               ["key:Set-Cookie"],
               ["key:access_token"],
               ["key:password"],
               ["key:private_key"],
               ["key:user", "key:AUTHORIZATION"],
               ["key:user", "key:profile", "index:0", "key:client_secret"]
             ]

      assert Enum.all?(records, &(&1["reason"] == "credential_key"))
    end

    test "credential key names are recognised in their common spellings" do
      for key <- [
            "password",
            "passwd",
            "db_password_hash",
            "secret_key_base",
            "csrf_token",
            "apikey",
            "x-api-key",
            "authorization",
            "cookie",
            "private_key",
            "PrivateKey",
            "aws_access_key_id",
            "credentials",
            "signing_key",
            "passphrase",
            :password,
            :api_key
          ] do
        assert Credentials.credential_key?(key), "#{inspect(key)} should be a credential key"
      end

      for key <- ["source", "query", "user_id", "repo", "author", "duration", 42, {:a}] do
        refute Credentials.credential_key?(key), "#{inspect(key)} is not a credential key"
      end
    end

    test "a key too long to classify is treated as a credential key and its path is cut on a character" do
      long = "a" <> String.duplicate("é", 200)
      assert Credentials.credential_key?(long)

      {masked, [record]} = Credentials.mask(%{long => "plain value"})

      assert masked == %{long => "[REDACTED:credential_key]"}
      # 64 bytes would end inside an é, so the segment keeps 63.
      assert record["path"] == ["key:a" <> String.duplicate("é", 31)]
      assert String.valid?(hd(record["path"]))
    end

    test "a non-string key is named by its inspected form in a record path" do
      {masked, records} = Credentials.mask(%{7 => "token=synthetic", password: "synthetic"})

      assert masked[:password] == "[REDACTED:credential_key]"
      assert masked[7] == "token=[REDACTED:credential_assignment]"

      assert records |> Enum.map(&{&1["path"], &1["reason"]}) |> Enum.sort() == [
               {["key:7"], "credential_assignment"},
               {["key::password"], "credential_key"}
             ]
    end
  end

  describe "URL userinfo without a secret" do
    test "an empty userinfo or an empty password leaves the URL as it is" do
      for text <- ["http://@localhost/x", "redis://user:@localhost:6379"] do
        assert Credentials.mask_text(text) == text
      end
    end
  end

  describe "secret-shaped strings" do
    test "each shape is masked in place and leaves the surrounding text readable" do
      cases = [
        {"auth header Authorization: Bearer abcdefghijklmnop0123 sent", "authorization_header"},
        {"basic Basic dXNlcjpzeW50aGV0aWM= sent", "authorization_header"},
        {"token #{@jwt} accepted", "jwt"},
        {"key #{@pem} loaded", "pem_block"},
        {"charging with #{@stripe} now", "provider_key"},
        {"aws #{@aws} used", "provider_key"},
        {"github #{@github} used", "provider_key"},
        {"connect ecto://postgres:synthetic-pass@localhost/db", "url_credentials"},
        {"opaque #{@entropy} value", "high_entropy"},
        {"login password=synthetic-pass&next=1", "credential_assignment"},
        {~s(%User{email: "a@example.com", password: "synthetic-pass"}), "credential_assignment"},
        {~s(%{"api_key" => "synthetic-pass"}), "credential_assignment"},
        {~s([{"cookie", "_app_key=synthetic-pass"}]), "credential_assignment"},
        {~s({:secret, "synthetic-pass"}), "credential_assignment"}
      ]

      for {text, reason} <- cases do
        masked = Credentials.mask_text(text)
        assert masked =~ "[REDACTED:#{reason}]", "#{text} → #{masked}"
        refute masked =~ "synthetic", "#{text} → #{masked}"
        refute masked =~ ~r/Bearer|Basic dX|eyJ|BEGIN|sk_live|AKIA|ghp_/
      end

      assert Credentials.mask_text("connect ecto://postgres:synthetic-pass@localhost/db") ==
               "connect ecto://postgres:[REDACTED:url_credentials]@localhost/db"

      assert Credentials.mask_text("login password=synthetic-pass&next=1") ==
               "login password=[REDACTED:credential_assignment]&next=1"
    end

    test "a credential-named field holding a container in inspect text is masked whole" do
      conn =
        ~s(%Plug.Conn{cookies: %{"_app_key" => "SFMy.synthetic", "n" => %{"x" => 1}}, ) <>
          ~s(host: "localhost", secrets: [{"a", "synthetic"}], cookie_jar: %{}, ) <>
          ~s(private_keys: %Key{id: 1, body: "synthetic"}, port: 4000})

      assert Credentials.mask_text(conn) ==
               "%Plug.Conn{cookies: [REDACTED:credential_assignment], " <>
                 ~s(host: "localhost", secrets: [REDACTED:credential_assignment], ) <>
                 "cookie_jar: [REDACTED:credential_assignment], " <>
                 "private_keys: [REDACTED:credential_assignment], port: 4000}"

      # A container cut off by truncation is masked to the end.
      assert Credentials.mask_text(~s(x: 1, tokens: %{"a" => "synthetic", "b" => [1, 2)) ==
               "x: 1, tokens: [REDACTED:credential_assignment]"
    end

    test "review regressions: sigils, tuple values, scheme case, long URLs, short text" do
      long_password = String.duplicate("a", 300)

      for {text, masked} <- [
            {~s(%Account{password: ~c"hunter2"}),
             "%Account{password: [REDACTED:credential_assignment]}"},
            {~s({"password", {"plain", "hunter2"}}),
             ~s({"password", [REDACTED:credential_assignment]})},
            {"Authorization: basic dXNlcjpwYXNz",
             "Authorization: [REDACTED:authorization_header]"},
            {"postgres://u:#{long_password}@localhost/db",
             "postgres://u:[REDACTED:url_credentials]@localhost/db"},
            {"token=x", "token=[REDACTED:credential_assignment]"},
            {"jwt=abc", "jwt=[REDACTED:credential_assignment]"},
            {"Authorization: Bearer abc", "Authorization: [REDACTED:authorization_header]"},
            {"cut postgres://u:aaaaaaaa", "cut postgres://u:[REDACTED:url_credentials]"}
          ] do
        assert Credentials.mask_text(text) == masked
      end
    end

    test "url_credentials masks userinfo in every URL shape and never a host:port" do
      marker = "[REDACTED:url_credentials]"

      # Ports, IPv6 hosts, queries and fragments, inspect punctuation, and
      # text without a scheme stay readable.
      unchanged = [
        "http://127.0.0.1:4100",
        "http://127.0.0.1:4100/graphql",
        "http://localhost:4100?x=1",
        "http://localhost:4100#frag",
        "http://localhost:4100?next=a@b.example",
        "http://localhost:4100?x=1 then more",
        ~s(%{url: "http://127.0.0.1:4100"}),
        ~s(%{url: "http://localhost:4100?x=1"}),
        ~s(%{"base_url" => "http://localhost:4000", "x" => 1}),
        "['http://localhost:4000']",
        "<http://localhost:4000>",
        "http://[::1]:4000",
        "http://[::1]:4000/path",
        "http://[::1]:4000?x=1",
        ~s(%{url: "http://[2001:db8::1]:8080"}),
        "http://localhost?q=a:b@c",
        "127.0.0.1:4100",
        "localhost:4000/graphql",
        "user:synthetic-pass@host:4000",
        # A later field's `@` never turns a port into a password.
        ~s({"url":"http://localhost:4100","email":"a@b.example"}),
        ~s(["http://localhost:4100","a@b.example"]),
        ~s({"url":"http://localhost:4100","n":1}),
        ~s({"url":"http://localhost","to":"x:y@z"}),
        "connect #{marker}"
      ]

      for text <- unchanged, do: assert(Credentials.mask_text(text) == text, text)

      # The password is masked whatever RFC 3986 userinfo characters it or the
      # user name holds, before any host shape, and when a cut removed `@host`.
      for {text, masked} <- [
            {"http://user:synthetic-pass@127.0.0.1:4100", "http://user:#{marker}@127.0.0.1:4100"},
            {"postgres://u:synthetic-pass@[::1]:5432/db", "postgres://u:#{marker}@[::1]:5432/db"},
            {"postgres://u:pa'ss@localhost/db", "postgres://u:#{marker}@localhost/db"},
            {"postgres://o'brien:synthetic@localhost/db",
             "postgres://o'brien:#{marker}@localhost/db"},
            {"redis://u:p!$&()*+,;=~x@h:6379", "redis://u:#{marker}@h:6379"},
            {"redis://u:p%40ss@h", "redis://u:#{marker}@h"},
            {"amqp://u:p:a:ss@h", "amqp://u:#{marker}@h"},
            {"amqp://u:pa?ss@h", "amqp://u:#{marker}@h"},
            {"amqp://u:pa#ss@h", "amqp://u:#{marker}@h"},
            {~s({"url":"postgres://u:pa'ss@h/db","email":"a@b.example"}),
             ~s({"url":"postgres://u:#{marker}@h/db","email":"a@b.example"})},
            {~s(["redis://u:p,ss@h","a@b.example"]), ~s(["redis://u:#{marker}@h","a@b.example"])},
            {"redis://:synthetic-pass@h:6379", "redis://:#{marker}@h:6379"},
            {~s(%{url: "redis://u:12345@localhost:6379"}),
             ~s(%{url: "redis://u:#{marker}@localhost:6379"})},
            {"http://u:4100@h", "http://u:#{marker}@h"},
            {"http://u:p@h?next=x@y", "http://u:#{marker}@h?next=x@y"},
            # A password with a numeric prefix and
            # sub-delimiters is a password, not a port.
            {"redis://u:123,ss@h", "redis://u:#{marker}@h"},
            {"postgres://u:123;ss@localhost/db", "postgres://u:#{marker}@localhost/db"},
            {"postgres://u:123'ss@localhost/db", "postgres://u:#{marker}@localhost/db"},
            {"postgres://u:123)ss@localhost/db", "postgres://u:#{marker}@localhost/db"},
            # A cut password inside a serialized value keeps its delimiters.
            {~s({"url":"postgres://u:cut-pass"}), ~s({"url":"postgres://u:#{marker}"})},
            {~s(["postgres://u:cut-pass"]), ~s(["postgres://u:#{marker}"])},
            {~s(%{url: "postgres://u:cut-pass"}), ~s(%{url: "postgres://u:#{marker}"})},
            {~s({"url":"postgres://u:123,x"}), ~s({"url":"postgres://u:#{marker}"})},
            # Userinfo without a password is masked whole; it may be a token.
            {"https://ghp-synthetic-token@github.com/o/r", "https://#{marker}@github.com/o/r"},
            # A second URL behind an unmasked-looking first one is scanned too.
            {"http://a:b,postgres://u:synthetic@h", "http://a:#{marker}//u:#{marker}@h"},
            # Ambiguous unquoted lists fail closed: `localhost:4100,a` could be
            # `user:password`.
            {"http://localhost:4100,a@b.example", "http://localhost:#{marker}@b.example"},
            {"http://localhost:4100;a@b.example", "http://localhost:#{marker}@b.example"},
            # An empty "port" is no port.
            {"postgres://u:?synth@h", "postgres://u:#{marker}@h"},
            {"postgres://u:#synth@h", "postgres://u:#{marker}@h"},
            {"postgres://u:;)", "postgres://u:#{marker}"},
            {"postgres://u:',", "postgres://u:#{marker}"},
            {"cut postgres://u:aaaaaaaa", "cut postgres://u:#{marker}"},
            {"cut postgres://u:pa'ss", "cut postgres://u:#{marker}"},
            {"cut postgres://u:pa?ss", "cut postgres://u:#{marker}"},
            {"cut postgres://u:pa#s", "cut postgres://u:#{marker}"}
          ] do
        assert Credentials.mask_text(text) == masked, text
        refute Credentials.mask_text(text) =~ ~r/synthetic|cut-pass|123[,;')]ss/
        assert Credentials.mask_text(masked) == masked, "idempotent: #{masked}"
      end
    end

    test "a URL authority is classified up to the limit and masked whole beyond it" do
      marker = "[REDACTED:url_credentials]"
      limit = Credentials.max_url_authority_bytes()

      # `bytes` of padding, exactly; multibyte padding is `é` (two bytes)
      # topped up with one ASCII byte when `bytes` is odd.
      pad = fn
        bytes, :ascii ->
          String.duplicate("a", bytes)

        bytes, :multibyte ->
          String.duplicate("é", div(bytes, 2)) <> String.duplicate("a", rem(bytes, 2))
      end

      # Each shape builds the authority candidate (the text after `scheme://`
      # up to its delimiter) of exactly `length` bytes, the full text around
      # it, and the expected output when it is classified and when it is
      # masked whole. The user name is kept only when classified.
      shapes = [
        {"long password",
         fn length ->
           candidate = "u:" <> pad.(length - 14, :ascii) <> "synth-tail@h"

           {candidate, "postgres://" <> candidate, "postgres://u:#{marker}@h",
            "postgres://#{marker}@h"}
         end},
        {"long user name",
         fn length ->
           user = pad.(length - 13, :ascii)
           candidate = user <> ":synth-pass@h"

           {candidate, "postgres://" <> candidate, "postgres://#{user}:#{marker}@h",
            "postgres://#{marker}@h"}
         end},
        {"multibyte password",
         fn length ->
           candidate = "u:" <> pad.(length - 17, :multibyte) <> "é-synth-tail@h"

           {candidate, "postgres://" <> candidate, "postgres://u:#{marker}@h",
            "postgres://#{marker}@h"}
         end},
        {"multibyte user name",
         fn length ->
           user = pad.(length - 13, :multibyte)
           candidate = user <> ":synth-pass@h"

           {candidate, "postgres://" <> candidate, "postgres://#{user}:#{marker}@h",
            "postgres://#{marker}@h"}
         end},
        {"cut password in JSON",
         fn length ->
           candidate = "u:" <> pad.(length - 11, :ascii) <> "synth-cut"

           {candidate, ~s({"url":"postgres://#{candidate}"}),
            ~s({"url":"postgres://u:#{marker}"}), ~s({"url":"postgres://#{marker}"})}
         end}
      ]

      for {name, build} <- shapes, length <- [limit - 1, limit, limit + 1] do
        {candidate, text, classified, whole} = build.(length)
        label = "#{name}, #{length} bytes"

        assert byte_size(candidate) == length, label
        assert String.valid?(candidate), label

        expected = if length <= limit, do: classified, else: whole
        masked = Credentials.mask_text(text)

        assert masked == expected, label
        refute masked =~ "synth", label
        assert String.valid?(masked), label
        assert {:ok, _json} = Jason.encode(masked)
        # Masking again never reveals anything. (A classified long user name
        # plus the marker can exceed the limit, so a second pass may mask the
        # user name too.)
        refute Credentials.mask_text(masked) =~ "synth", label

        assert {%{"u" => ^masked}, [%{"reason" => "url_credentials", "count" => 1}]} =
                 Credentials.mask(%{"u" => text})
      end
    end

    test "an earlier mask inside URL userinfo never ends its inspection" do
      marker = "[REDACTED:url_credentials]"
      ghp = "ghp_" <> String.duplicate("1", 20)
      jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl"

      for {text, masked} <- [
            {"postgres://u:#{ghp}:synth-tail@localhost/db",
             "postgres://u:#{marker}@localhost/db"},
            {"https://#{ghp}:synth-pass@localhost/db",
             "https://[REDACTED:provider_key]:#{marker}@localhost/db"},
            {"https://u:#{jwt}synth@h", "https://u:#{marker}@h"},
            {"https://#{jwt}:synth-pass@h", "https://[REDACTED:jwt]:#{marker}@h"},
            {"https://#{ghp}@h/x", "https://#{marker}@h/x"},
            {"cut https://u:#{ghp}:synth", "cut https://u:#{marker}"},
            {~s({"url":"https://#{ghp}:synth-pass@h"}),
             ~s({"url":"https://[REDACTED:provider_key]:#{marker}@h"})},
            # Text that already holds markers from an earlier pass.
            {"postgres://u:[REDACTED:provider_key]:synth-tail@h", "postgres://u:#{marker}@h"},
            {"https://[REDACTED:jwt]:synth-pass@h", "https://[REDACTED:jwt]:#{marker}@h"}
          ] do
        assert Credentials.mask_text(text) == masked, text
        refute Credentials.mask_text(masked) =~ "synth"
        assert Credentials.mask_text(masked) == masked, "idempotent: #{masked}"
      end

      # An IP literal host is still not userinfo.
      assert Credentials.mask_text("http://[::1]:4000") == "http://[::1]:4000"
    end

    test "only the policy's own reasons in bracketed text become records" do
      text = Enum.map_join(1..40, " ", &"[REDACTED:#{String.duplicate("a", &1)}]")
      assert {_masked, []} = Credentials.mask(%{"message" => text})
    end

    test "no pattern backtracks without bound on 8 KiB adversarial input" do
      inputs = [
        String.duplicate("aB3", 2_730) <> "===",
        String.duplicate("x", 8_000) <> "token",
        "\"" <> String.duplicate("secretx", 1_100),
        String.duplicate("eyJabcd", 1_150),
        String.duplicate("password_", 900) <> " "
      ]

      for {reason, regex} <- Credentials.patterns(), input <- inputs do
        result =
          :re.run(input, regex.re_pattern, [:global, :report_errors, {:match_limit, 2_000_000}])

        refute match?({:error, _}, result), "#{reason} exceeded its match limit"
      end
    end

    test "a secret cut off by truncation is still masked" do
      assert Credentials.mask_text("-----BEGIN RSA PRIVATE KEY-----\nMIIEvSynth") ==
               "[REDACTED:pem_block]"

      assert Credentials.mask_text(~s(password: "synthetic-unterminated)) ==
               "password: [REDACTED:credential_assignment]"

      assert Credentials.mask_text(String.slice(@jwt, 0, 40)) =~ "[REDACTED:jwt]"
    end

    test "masking again changes nothing" do
      for text <- [
            ~s(%{"secret" => "synthetic", "api_key" => 'x', token: "y"}),
            ~s([{"authorization", "Bearer abcdefghijklmnop0123"}]),
            "password=x&token=y DATABASE_URL=ecto://u:synthetic@h/db #{@jwt}"
          ] do
        once = Credentials.mask_text(text)
        refute once =~ "synthetic"
        assert Credentials.mask_text(once) == once
      end
    end

    test "ordinary diagnostic text is left alone" do
      for text <- [
            ~s[SELECT u0."id", u0."email" FROM "users" AS u0 WHERE (u0."password_hash" = $1)],
            "GET /api/v1/listings 200 in 12ms",
            "550e8400-e29b-41d4-a716-446655440000",
            "4bf92f3577b34da6a3ce929d0e0e4736",
            String.duplicate("ab12", 16),
            "binary-sha256:" <> String.duplicate("0f", 32),
            "lib/insider/live/owner.ex:120",
            "Elixir.MyApp.Repo",
            "the token expired",
            "[REDACTED:jwt] already masked",
            ""
          ] do
        assert Credentials.mask_text(text) == text
      end
    end

    test "strings inside lists and maps are masked with one record per path and reason" do
      value = %{
        "message" => "sent Bearer abcdefghijklmnop0123 and #{@stripe}",
        "params" => ["ok", @jwt, %{"inner" => [@aws, @aws]}]
      }

      {masked, records} = Credentials.mask(value)

      assert masked["message"] ==
               "sent [REDACTED:authorization_header] and [REDACTED:provider_key]"

      assert masked["params"] == [
               "ok",
               "[REDACTED:jwt]",
               %{"inner" => ["[REDACTED:provider_key]", "[REDACTED:provider_key]"]}
             ]

      assert Enum.sort_by(records, &{&1["path"], &1["reason"]}) == [
               mask_record(["key:message"], "authorization_header", 1),
               mask_record(["key:message"], "provider_key", 1),
               mask_record(["key:params", "index:1"], "jwt", 1),
               mask_record(["key:params", "index:2", "key:inner", "index:0"], "provider_key", 1),
               mask_record(["key:params", "index:2", "key:inner", "index:1"], "provider_key", 1)
             ]
    end

    test "markers left by capture-time masking are reported at export" do
      {masked, records} = Credentials.mask(%{"message" => "a [REDACTED:jwt] b [REDACTED:jwt]"})
      assert masked == %{"message" => "a [REDACTED:jwt] b [REDACTED:jwt]"}
      assert records == [mask_record(["key:message"], "jwt", 2)]
    end

    test "the manifest is bounded but keeps every reason" do
      value =
        Map.new(
          1..100,
          &{"k#{&1}", %{"password" => "x", "note" => "Bearer abcdefghijklmnop0123"}}
        )

      {_masked, records} = Credentials.mask(value)

      assert Enum.count_until(records, 33) <= 32
      assert records |> Enum.map(& &1["count"]) |> Enum.sum() == 200

      assert records |> Enum.map(& &1["reason"]) |> Enum.uniq() |> Enum.sort() ==
               ["authorization_header", "credential_key"]
    end

    test "deep paths are cut to eight segments" do
      deep = Enum.reduce(1..12, "password=x", fn index, acc -> %{"l#{index}" => acc} end)
      {_masked, [record]} = Credentials.mask(deep)
      assert record["path"] == Enum.map(12..5//-1, &"key:l#{&1}")
    end

    test "the reason vocabulary is closed" do
      assert Credentials.reasons() == [
               "authorization_header",
               "credential_assignment",
               "credential_key",
               "high_entropy",
               "jwt",
               "pem_block",
               "provider_key",
               "redacted_field",
               "url_credentials"
             ]
    end
  end

  defp record(records, path), do: Enum.find(records, &(&1["path"] == path))

  defp mask_record(path, reason, count) do
    %{
      "action" => "mask",
      "count" => count,
      "path" => path,
      "policy_id" => "insider-credential-masking/v1",
      "reason" => reason
    }
  end
end
