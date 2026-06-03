.PHONY: fmt ci-format ci-lint ci-build-check ci-release-readiness lockfile spec-check

fmt:

ci-format:

ci-lint:

ci-build-check:

ci-release-readiness:

lockfile:

spec-check: ## L1 ADR-0086: SPEC.md exists and wire_surface is valid
	@SPEC=SPEC.md; \
	VALID="proto-source utoipa-legacy mixed-transition"; \
	[ -f "$$SPEC" ] || { echo "ERROR: $$SPEC missing (ADR-0086 L1)"; exit 1; }; \
	WS=$$(awk 'BEGIN{f=0}/^---/{f=!f;next}f&&/^wire_surface:/{print $$2;exit}' "$$SPEC"); \
	[ -n "$$WS" ] || { echo "ERROR: wire_surface field missing (ADR-0086 L1)"; exit 1; }; \
	echo "$$VALID" | tr ' ' '\n' | grep -qx "$$WS" \
		|| { echo "ERROR: wire_surface='$$WS' invalid. Must be one of: $$VALID"; exit 1; }; \
	echo "spec-check OK: wire_surface=$$WS"
