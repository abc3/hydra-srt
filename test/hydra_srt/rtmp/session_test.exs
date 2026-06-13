defmodule HydraSrt.Rtmp.SessionTest do
  use ExUnit.Case, async: true

  alias ExRTMP.AMF0
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection.Response
  alias HydraSrt.Rtmp.Session

  describe "handle_command_message/2 for RTMP RPC commands" do
    test "getStreamLength returns numeric zero for live streams" do
      session = connected_session()
      command = command_message(["getStreamLength", 4.0, nil])

      {^session, [outbound]} = Session.handle_command_message(session, command)

      assert %Response{result: "_result", transaction_id: 4, data: 0} = outbound.payload

      amf =
        outbound.payload
        |> Message.Serializer.serialize()
        |> IO.iodata_to_binary()

      assert [result, txn, _command_object, data] = AMF0.parse(amf)
      assert result == "_result"
      assert txn == 4.0
      assert data == 0.0
    end

    test "_checkbw returns null result data" do
      session = connected_session()
      command = command_message(["_checkbw", 2.0, nil])

      {^session, [outbound]} = Session.handle_command_message(session, command)

      assert %Response{result: "_result", transaction_id: 2, data: nil} = outbound.payload
    end

    test "unknown commands return null result data instead of empty object" do
      session = connected_session()
      command = command_message(["FCSubscribe", 3.0, nil, "stream"])

      {^session, [outbound]} = Session.handle_command_message(session, command)

      assert %Response{result: "_result", transaction_id: 3, data: nil} = outbound.payload
    end
  end

  defp connected_session do
    %Session{phase: :connected, stream_id: 1, peer: {{127, 0, 0, 1}, 42_000}}
  end

  defp command_message(payload) do
    Message.new(payload, type: 20, timestamp: 0, stream_id: 0)
  end
end
