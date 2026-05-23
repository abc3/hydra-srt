ERL_AFLAGS = +zdbbl 2097150

user ?= admin
pass ?= password123

help:
	@make -qpRr | egrep -e '^[a-z].*:$$' | sed -e 's~:~~g' | sort

.PHONY: dev
dev:
	@echo "Cleaning stale dev processes on :4000 and :5173 (if any)..."
	@for port in 4000 5173; do \
		pids=$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null); \
		if [ -n "$$pids" ]; then \
			kill -15 $$pids 2>/dev/null || true; \
		fi; \
	done
	MIX_ENV=dev \
	VAULT_ENC_KEY="12345678901234567890123456789012" \
	API_JWT_SECRET=dev \
	METRICS_JWT_SECRET=dev \
	API_AUTH_USERNAME=${user} \
	API_AUTH_PASSWORD=${pass} \
	ANALYTICS_DATABASE_PATH=./hydra_srt_analytics.duckdb \
	DEMO_DATA=true \
	ERL_AFLAGS="-kernel shell_history enabled +zdbbl 2097151" \
	iex --name hydra@127.0.0.1 --cookie cookie -S mix phx.server --no-halt

.PHONY: dev_stop
dev_stop:
	@echo "Stopping dev processes on :4000 and :5173..."
	@for port in 4000 5173; do \
		pids=$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null); \
		if [ -n "$$pids" ]; then \
			kill -15 $$pids 2>/dev/null || true; \
		fi; \
	done

clean:
	rm -rf _build && rm -rf deps

dev_udp0:
	ffmpeg -f lavfi -re -i smptebars=duration=6000:size=1280x720:rate=25 -f lavfi -re -i sine=frequency=1000:duration=6000:sample_rate=44100 \
	-pix_fmt yuv420p -c:v libx264 -b:v 1000k -g 25 -keyint_min 100 -profile:v baseline -preset veryfast \
	-f mpegts "udp://224.0.0.3:1234?pkt_size=1316"

dev_udp1:
	ffmpeg -hide_banner -loglevel error -re \
	-f lavfi -i smptebars=duration=6000:size=1280x720:rate=25 \
	-f lavfi -i sine=frequency=1000:duration=6000:sample_rate=44100 \
	-pix_fmt yuv420p -c:v libx264 -b:v 1000k -g 25 -keyint_min 100 -profile:v baseline -preset veryfast \
	-c:a aac -b:a 128k -ar 48000 -ac 2 \
	-f mpegts "srt://127.0.0.1:4201?mode=listener"	

dev_udp:
	ffmpeg -hide_banner -loglevel error -re \
	-f lavfi -i "testsrc=size=1280x720:rate=30" \
	-f lavfi -i "sine=frequency=440:sample_rate=48000" \
	-c:v libx264 -preset veryfast -tune zerolatency -b:v 2000k \
	-c:a aac -b:a 128k \
	-f mpegts "srt://127.0.0.1:4200?mode=listener"

dev_play:
	ffplay -hide_banner "udp://127.0.0.1:1234"

dev_play1:
	srt-live-transmit "srt://127.0.0.1:4201?mode=caller" udp://:4204 -v -statspf default -stats 1000

dev_udp2:
	ffmpeg -hide_banner -loglevel error \
	-i "srt://127.0.0.1:4210?mode=listener" \
	-f mpegts "udp://127.0.0.1:1234?pkt_size=1316"

docker_restart:
	docker compose down && docker compose up -d

.PHONY: docker_rebuild
docker_rebuild:
	docker compose down
	docker compose build --no-cache
	docker compose up -d

.PHONY: docker_env
docker_env:
	@echo "DATABASE_PATH=/app/db/hydra_srt.db" > .env
	@echo "Wrote .env (DATABASE_PATH=/app/db/hydra_srt.db)"

docker_ssh:
	docker compose exec hydra_srt bash

docker_logs:
	docker compose logs -f

docker_stop:
	docker compose down

docker_start:
	docker compose up -d

docker_host_up:
	PHX_HOST=$$(hostname -I | awk '{print $$1}') docker-compose -f docker-compose.yml -f docker-compose.host.yml up -d

docker_host_down:
	docker-compose -f docker-compose.yml -f docker-compose.host.yml down

docker_host_logs:
	docker-compose -f docker-compose.yml -f docker-compose.host.yml logs -f hydra_srt

docker_host_rebuild:
	docker-compose -f docker-compose.yml -f docker-compose.host.yml down
	PHX_HOST=$$(hostname -I | awk '{print $$1}') docker-compose -f docker-compose.yml -f docker-compose.host.yml build --no-cache
	PHX_HOST=$$(hostname -I | awk '{print $$1}') docker-compose -f docker-compose.yml -f docker-compose.host.yml up -d

docker_host_down2:
	docker compose -f docker-compose.yml -f docker-compose.host.yml down

docker_host_rebuild2:
	docker compose -f docker-compose.yml -f docker-compose.host.yml down
	docker compose -f docker-compose.yml -f docker-compose.host.yml build --no-cache
	docker compose -f docker-compose.yml -f docker-compose.host.yml up -d

docker_clean:
	docker compose down && docker compose rm -f hydra_srt

.PHONY: credence credence_all
credence:
	@files=$$(git status --porcelain -u \
		| sed -E 's/^.. //; s/.* -> //' \
		| grep -E '\.(ex|exs)$$' \
		| while read -r f; do [ -f "$$f" ] && echo "$$f"; done \
		| sort -u); \
	if [ -z "$$files" ]; then \
		echo "credence: no changed Elixir files (git status)"; \
		exit 0; \
	fi; \
	echo "credence: $$files"; \
	mix credence $$files
credence_all:
	mix credence

.PHONY: test_e2e
test_e2e:
	E2E=true mix test --only e2e

.PHONY: test_rs_native_e2e
test_rs_native_e2e:
	NATIVE_E2E=true mix test test/native_e2e

.PHONY: test_e2e_encrypted
test_e2e_encrypted:
	E2E=true mix test --only encrypted

.PHONY: test_e2e_mcp
test_e2e_mcp:
	E2E_MCP=true mix test --only e2e_mcp

.PHONY: test_backend
test_backend:
	mix test

.PHONY: test_backend_e2e
test_backend_e2e:
	E2E=true mix test --only e2e

.PHONY: test_backend_e2e_encrypted
test_backend_e2e_encrypted:
	E2E=true mix test --only encrypted

.PHONY: test_rs_native_unit
test_rs_native_unit:
	cd native && cargo test

.PHONY: test_web_unit
test_web_unit:
	cd web_app && npm run test:unit

.PHONY: test_web_e2e
test_web_e2e:
	cd web_app && npm run test:e2e

.PHONY: test_all
test_all:
	@echo "Running: backend unit tests"
	@$(MAKE) test_backend
	@echo "Running: backend e2e tests"
	@$(MAKE) test_backend_e2e
	@echo "Running: native unit tests (cargo)"
	@$(MAKE) test_rs_native_unit
	@echo "Running: web unit tests (vitest)"
	@$(MAKE) test_web_unit
	@echo "Running: web e2e tests (playwright)"
	@$(MAKE) test_web_e2e

.PHONY: test_ci_local
test_ci_local:
	@echo "Running CI-equivalent local suite"
	@echo "1/7 Native unit tests"
	cd native && cargo test -- --nocapture
	@echo "2/7 Native E2E tests"
	MIX_ENV=test NATIVE_E2E=true mix deps.get
	MIX_ENV=test NATIVE_E2E=true mix deps.compile
	MIX_ENV=test NATIVE_E2E=true $(MAKE) test_rs_native_e2e
	@echo "3/7 JS unit tests"
	cd web_app && npm ci && npm run test:unit
	@echo "4/7 JS E2E tests"
	MIX_ENV=test mix deps.get
	MIX_ENV=test mix deps.compile
	cd native && cargo build
	cd web_app && npx playwright install --with-deps && npm run test:e2e
	@echo "5/7 Elixir unit tests"
	MIX_ENV=test mix deps.get
	MIX_ENV=test mix deps.compile
	MIX_ENV=test mix compile --warnings-as-errors
	MIX_ENV=test mix format --check-formatted
	MIX_ENV=test mix sobelow
	MIX_ENV=test mix test
	@echo "6/7 Elixir MCP E2E tests"
	cd native && cargo build
	mkdir -p priv/native/build
	cp native/target/debug/hydra_srt_pipeline priv/native/build/
	@$(MAKE) test_e2e_mcp
	@echo "7/7 Elixir E2E tests"
	MIX_ENV=test E2E=true mix deps.get
	cd native && cargo build
	mkdir -p priv/native/build
	cp native/target/debug/hydra_srt_pipeline priv/native/build/
	MIX_ENV=test E2E=true mix test --only e2e

.PHONY: drop_analytics_db
drop_analytics_db:
	rm -f hydra_srt_analytics.*
