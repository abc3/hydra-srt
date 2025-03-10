help:
	@make -qpRr | egrep -e '^[a-z].*:$$' | sed -e 's~:~~g' | sort

.PHONY: dev
dev:
	MIX_ENV=dev \
	VAULT_ENC_KEY="12345678901234567890123456789012" \
	API_JWT_SECRET=dev \
	METRICS_JWT_SECRET=dev \
	VICTORIOMETRICS_HOST=localhost \
	VICTORIOMETRICS_PORT=8428 \
	API_AUTH_USERNAME=admin \
	API_AUTH_PASSWORD=password123 \
	ERL_AFLAGS="-kernel shell_history enabled +zdbbl 2097151" \
	iex --name hydra@127.0.0.1 --cookie cookie -S mix phx.server --no-halt

clean:
	rm -rf _build && rm -rf deps

dev_udp0:
	ffmpeg -f lavfi -re -i smptebars=duration=6000:size=1280x720:rate=25 -f lavfi -re -i sine=frequency=1000:duration=6000:sample_rate=44100 \
	-pix_fmt yuv420p -c:v libx264 -b:v 1000k -g 25 -keyint_min 100 -profile:v baseline -preset veryfast \
	-f mpegts "udp://224.0.0.3:1234?pkt_size=1316"

dev_udp:
	ffmpeg -f lavfi -re -i smptebars=duration=6000:size=1280x720:rate=25 -f lavfi -re -i sine=frequency=1000:duration=6000:sample_rate=44100 \
	-pix_fmt yuv420p -c:v libx264 -b:v 1000k -g 25 -keyint_min 100 -profile:v baseline -preset veryfast \
	-f mpegts "srt://127.0.0.1:4201?mode=listener"	

dev_play:
	ffplay udp://224.0.0.3:1234

dev_play1:
	srt-live-transmit "srt://127.0.0.1:4201?mode=listener" udp://:1234 -v -statspf default -stats 1000

dev_udp1:
	ffmpeg -i "srt://127.0.0.1:4201?mode=caller" -f mpegts udp://239.0.0.1:1234?pkt_size=1316		
