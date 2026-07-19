defmodule HydraSrt.Ndi.FeaturePolicyTest do
  use ExUnit.Case, async: false

  alias HydraSrt.Ndi.FeaturePolicy

  setup do
    previous = Application.get_env(:hydra_srt, :ndi, :__unset__)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:hydra_srt, :ndi)
        value -> Application.put_env(:hydra_srt, :ndi, value)
      end
    end)

    :ok
  end

  test "all flags default false when :ndi env is unset" do
    Application.delete_env(:hydra_srt, :ndi)

    refute FeaturePolicy.enabled?()
    refute FeaturePolicy.receive?()
    refute FeaturePolicy.send?()
    assert FeaturePolicy.deny_reason(:enabled) == "NDI_DISABLED"
    assert FeaturePolicy.deny_reason(:discovery) == "NDI_DISABLED"
    assert FeaturePolicy.deny_reason(:receive) == "NDI_DISABLED"
    assert FeaturePolicy.deny_reason(:send) == "NDI_DISABLED"
  end

  test "enabled alone does not grant receive or send" do
    Application.put_env(:hydra_srt, :ndi, enabled: true)

    assert FeaturePolicy.enabled?()
    refute FeaturePolicy.receive?()
    refute FeaturePolicy.send?()
    assert FeaturePolicy.deny_reason(:enabled) == nil
    assert FeaturePolicy.deny_reason(:discovery) == nil
    assert FeaturePolicy.deny_reason(:receive) == "NDI_DISABLED"
    assert FeaturePolicy.deny_reason(:send) == "NDI_DISABLED"
  end

  test "receive and send require enabled and directional flag" do
    Application.put_env(:hydra_srt, :ndi, enabled: true, receive: true, send: true)

    assert FeaturePolicy.enabled?()
    assert FeaturePolicy.receive?()
    assert FeaturePolicy.send?()
    assert FeaturePolicy.deny_reason(:receive) == nil
    assert FeaturePolicy.deny_reason(:send) == nil
  end

  test "directional flags alone are insufficient without enabled" do
    Application.put_env(:hydra_srt, :ndi, enabled: false, receive: true, send: true)

    refute FeaturePolicy.enabled?()
    refute FeaturePolicy.receive?()
    refute FeaturePolicy.send?()
  end

  test "non-boolean flag values are treated as false" do
    Application.put_env(:hydra_srt, :ndi, enabled: "yes", receive: 1, send: nil)

    refute FeaturePolicy.enabled?()
    refute FeaturePolicy.receive?()
    refute FeaturePolicy.send?()
  end
end
