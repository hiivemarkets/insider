defmodule Insider.Sentinel.Verification.IngressTest do
  use ExUnit.Case, async: true

  alias Insider.Sentinel.Verification.Ingress

  test "decodes canonical JSON through the supplied decoder" do
    encoded = ~s({"ok":true})

    assert Ingress.canonical_decode(encoded, byte_size(encoded), fn wire -> {:decoded, wire} end) ==
             {:decoded, %{"ok" => true}}
  end

  test "rejects malformed and noncanonical JSON" do
    assert Ingress.canonical_decode("{", 64, &Function.identity/1) ==
             {:ingress_error, :invalid_json}

    assert Ingress.canonical_decode(~s({ "ok": true }), 64, &Function.identity/1) ==
             {:ingress_error, :noncanonical_encoding}
  end

  test "rejects inputs outside the byte boundary" do
    encoded = ~s({"ok":true})

    assert Ingress.canonical_decode(encoded, byte_size(encoded) - 1, &Function.identity/1) ==
             {:ingress_error, :limit_exceeded}

    assert Ingress.canonical_decode(:not_encoded, 64, &Function.identity/1) ==
             {:ingress_error, :invalid_encoding}
  end

  test "contains decoder failures at the ingress boundary" do
    assert Ingress.canonical_decode(~s({"ok":true}), 64, fn _wire -> raise "decoder failed" end) ==
             {:ingress_error, :decoding_failed}
  end
end
