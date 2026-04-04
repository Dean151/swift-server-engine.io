test: test-package test-engine

test-package:
	swift test

test-engine:
	docker compose run --build --rm engine-test npm test

down:
	docker compose down --remove-orphans
