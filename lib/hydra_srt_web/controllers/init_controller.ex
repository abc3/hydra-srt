defmodule HydraSrtWeb.InitController do
  use HydraSrtWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      version: app_version(),
      system_version: system_version(),
      elixir_version: System.version(),
      erlang_version: erlang_version(),
      rust_version: rust_version()
    })
  end

  defp app_version do
    :hydra_srt
    |> Application.spec(:vsn)
    |> List.to_string()
  end

  defp system_version do
    case System.cmd("uname", ["-srm"], stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      _ ->
        {os_family, os_name} = :os.type()
        "#{os_family}/#{os_name} (#{:erlang.system_info(:system_architecture)})"
    end
  end

  defp erlang_version do
    otp_release = :erlang.system_info(:otp_release) |> List.to_string()
    erts_version = :erlang.system_info(:version) |> List.to_string()
    "OTP #{otp_release} (ERTS #{erts_version})"
  end

  defp rust_version do
    case System.find_executable("rustc") do
      nil ->
        "unavailable"

      rustc_path ->
        case System.cmd(rustc_path, ["--version"], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          _ -> "unavailable"
        end
    end
  end
end
