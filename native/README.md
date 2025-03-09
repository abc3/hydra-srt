### debug input
{"source":{"type":"srtsrc","localaddress":"127.0.0.1","localport":8000,"auto-reconnect":true,"keep-listening":false,"mode":"listener"},"sinks":[{"type":"srtsink","localaddress":"127.0.0.1","localport":8002,"mode":"listener"},{"type":"udpsink","host":"127.0.0.1","port":8003}]}

{"source":{"type":"srtsrc","localaddress":"127.0.0.1","localport":8000,"auto-reconnect":true,"keep-listening":false,"mode":"listener", "streamid": "test1", "passphrase": "secure_pass_123", "pbkeylen": 16},"sinks":[{"type":"srtsink","localaddress":"127.0.0.1","localport":8002,"mode":"listener"},{"type":"udpsink","host":"127.0.0.1","port":8003}]}
