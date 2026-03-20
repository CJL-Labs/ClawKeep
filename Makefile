SHELL := /bin/zsh

.PHONY: build tidy

build:
	cd keepd && go build ./cmd/keepd

tidy:
	cd keepd && go mod tidy
