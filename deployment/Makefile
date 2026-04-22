help:
	@make -qpRr | egrep -e '^[a-z].*:$$' | sed -e 's~:~~g' | sort

.PHONY: tofu-init
tofu-init:
	cd opentofu && set -a && source .env && set +a && tofu init

.PHONY: tofu-plan
tofu-plan:
	cd opentofu && set -a && source .env && set +a && tofu plan

.PHONY: tofu-apply
tofu-apply:
	cd opentofu && set -a && source .env && set +a && tofu apply

.PHONY: tofu-destroy
tofu-destroy:
	cd opentofu && set -a && source .env && set +a && tofu destroy

.PHONY: tofu-validate
tofu-validate:
	cd opentofu && tofu validate

.PHONY: bootstrap-host
bootstrap-host:
	sudo ./scripts/bootstrap.sh

.PHONY: deploy-release
deploy-release:
	@test -n "$(HOST)" || (echo "Use: make deploy-release HOST=user@host [RELEASE_ID=name]" && exit 1)
	@if [ -n "$(RELEASE_ID)" ]; then \
		./scripts/deploy_release.sh "$(HOST)" "$(RELEASE_ID)"; \
	else \
		./scripts/deploy_release.sh "$(HOST)"; \
	fi
