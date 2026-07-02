.PHONY: demo demo-codex demo-claude build test

build:
	swift build -c release --product ringo

test:
	swift test

demo: demo-codex demo-claude

demo-codex:
	bash docs/record-all-demos.sh codex

demo-claude:
	bash docs/record-all-demos.sh claude
