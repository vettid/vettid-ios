module phoneiosreference

go 1.26.0

require github.com/vettid/vettid-vault v0.0.0

require (
	golang.org/x/crypto v0.57.0 // indirect
	golang.org/x/sys v0.48.0 // indirect
	golang.org/x/text v0.42.0 // indirect
)

// vettid-vault cloned next to this repository.
replace github.com/vettid/vettid-vault => ../../../vettid-vault
