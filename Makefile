SHELL := /bin/zsh

.PHONY: build tidy

build:
	cd sentineld && go build ./cmd/sentineld

tidy:
	cd sentineld && go mod tidy
