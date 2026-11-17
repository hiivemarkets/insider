defmodule Insider.ProtectedTargetAuditMatrixTest do
  use ExUnit.Case, async: true

  alias Insider.Event.Canonical
  alias Insider.Policy.ProtectedTargets

  # Regenerate with:
  #   mix run --no-start -e '{:ok, matrix} = Insider.Policy.ProtectedTargets.audit_matrix(); File.write!("docs/protected-target-audit-matrix.json", Insider.Event.Canonical.encode(matrix) <> "\n")'
  @matrix_path "docs/protected-target-audit-matrix.json"
  @expected_control_target_classes [
    "collector_process",
    "insider_supervisor",
    "recorder_process",
    "session_component_process",
    "session_manager",
    "session_process",
    "session_root_supervisor",
    "session_supervisor"
  ]

  test "committed matrix is the canonical derivation of the fixed inventory" do
    bytes = File.read!(@matrix_path)
    assert {:ok, matrix} = ProtectedTargets.audit_matrix()
    assert bytes == Canonical.encode(matrix) <> "\n"
    assert {:ok, decoded} = Jason.decode(bytes)
    assert decoded == matrix

    assert matrix["schema"] == "insider.protected-target-audit-matrix/v1"
    assert matrix["inventory_version"] == "otp_elixir_runtime_registry/v1"
    assert matrix["otp_majors"] == ["27", "28", "29"]
    assert matrix["controls"]["application_targets"] == "undeclared"
    assert matrix["controls"]["exception_review_owner"] == "undeclared"
    assert matrix["controls"]["exception_mechanism"] == "none"
    assert matrix["controls"]["runtime_inspection"] == "none"

    assert matrix["fingerprint"] == Canonical.sha256(Map.delete(matrix, "fingerprint"))
    assert ProtectedTargets.audit_matrix() == {:ok, matrix}
    assert ProtectedTargets.audit_matrix(otp_majors: ["29", "27", "28"]) == {:ok, matrix}
  end

  test "every matrix row is a fixed name or control class and is denied by the policy" do
    assert {:ok, matrix} = ProtectedTargets.audit_matrix()
    assert {:ok, policy} = ProtectedTargets.new()

    assert Enum.map(matrix["inventories"], & &1["otp_major"]) == ["27", "28", "29"]

    for inventory <- matrix["inventories"] do
      rows = inventory["rows"]
      assert Enum.all?(rows, &(&1["decision"] == "protected"))
      assert Enum.all?(rows, &(&1["otp_major"] == inventory["otp_major"]))

      registry_rows = Enum.filter(rows, &(&1["class"] == "beam_otp"))
      control_rows = Enum.filter(rows, &(&1["class"] == "insider_control_plane"))
      assert length(registry_rows) + length(control_rows) == length(rows)

      assert Enum.map(registry_rows, & &1["target"]) == policy.registration_names
      assert Enum.all?(registry_rows, &(&1["target_kind"] == "registered_name"))
      assert Enum.all?(registry_rows, &(&1["reason"] == "fixed_registry_inventory"))

      assert Enum.map(control_rows, & &1["target"]) == @expected_control_target_classes
      assert Enum.all?(control_rows, &(&1["target_kind"] == "control_target_class"))
      assert Enum.all?(control_rows, &(&1["reason"] == "collector_session_binding"))
    end

    current = Enum.find(matrix["inventories"], &(&1["otp_major"] == policy.otp_major))
    assert current["base_policy_fingerprint"] == policy.fingerprint

    registered =
      for row <- current["rows"],
          row["class"] == "beam_otp",
          pid = Process.whereis(String.to_existing_atom(row["target"])),
          is_pid(pid),
          do: {row["target"], pid}

    assert Enum.count_until(registered, 6) == 6
    assert Enum.any?(registered, &match?({"Elixir.Insider.Supervisor", _pid}, &1))
    assert Enum.any?(registered, &match?({"erts_code_purger", _pid}, &1))

    for {name, pid} <- registered do
      assert {:protected, %{"class" => "beam_otp"}} = ProtectedTargets.classify(policy, pid),
             "#{name} must be denied before inspection"
    end

    classes = Enum.map(matrix["classification"], & &1["class"])

    assert classes == [
             "invalid",
             "remote_or_invalid",
             "host_declared",
             "insider_control_plane",
             "beam_otp",
             "none"
           ]

    assert Enum.map(matrix["classification"], & &1["precedence"]) == Enum.to_list(0..5)
    assert {:protected, %{"class" => "invalid"}} = ProtectedTargets.classify(policy, :not_a_pid)
    assert {:allowed, %{"class" => "none"}} = ProtectedTargets.classify(policy, self())
  end

  test "matrix is PID-free, timestamp-free, publicly neutral, and option-strict" do
    bytes = File.read!(@matrix_path)
    assert {:ok, _matrix} = ProtectedTargets.audit_matrix()

    for forbidden <- [
          ~r/(\/users\/|\/private\/)/i,
          ~r/api_key/i,
          ~r/dsn=/i,
          ~r/authorization:\s*bearer/i,
          ~r/mix\s+deploy/i,
          ~r/<\d+\.\d+\.\d+>/,
          ~r/#PID/,
          ~r/\d{4}-\d{2}-\d{2}T/,
          ~r/approved|production_ready|authoriz/i
        ] do
      refute bytes =~ forbidden
    end

    assert {:ok, single} = ProtectedTargets.audit_matrix(otp_majors: ["30"])
    assert single["otp_majors"] == ["30"]
    assert Enum.map(single["inventories"], & &1["otp_major"]) == ["30"]

    for options <- [
          [otp_majors: ["27", "27"]],
          [otp_majors: ["twenty"]],
          [otp_majors: ["2700"]],
          [otp_majors: [27]],
          [otp_majors: Enum.map(1..9, &Integer.to_string/1)],
          [otp_majors: ["27"], otp_majors: ["28"]],
          [host_targets: []],
          %{otp_majors: ["27"]}
        ] do
      assert ProtectedTargets.audit_matrix(options) == {:error, :invalid_options},
             "#{inspect(options)} must be rejected"
    end
  end
end
