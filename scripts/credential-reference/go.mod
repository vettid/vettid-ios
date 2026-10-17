module credentialreference

go 1.26.0

require github.com/vettid/vettid-vault v0.0.0

require (
	github.com/coder/websocket v1.8.15 // indirect
	github.com/vettid/vettid-relay v0.0.0-20261015153542-cc3ce892f9dc // indirect
	golang.org/x/crypto v0.57.0 // indirect
	golang.org/x/text v0.42.0 // indirect
)

// vettid-vault cloned next to this repository.
replace github.com/vettid/vettid-vault => ../../../vettid-vault
