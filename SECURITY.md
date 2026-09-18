# Security Policy

Rivet is pre-1.0 and has not undergone an independent security audit.

Please do not publish a suspected vulnerability in a public issue. Use GitHub's private vulnerability reporting for this repository when available, or contact the repository owner privately.

Security-sensitive areas include RVT1 framing/decoding, native/Racket lifetime boundaries, runtime artifact selection, generated code escaping, package signing, DLL/framework loading, and untrusted input handled by application RPCs.

Rivet treats the Racket backend as trusted application code. The embedded backend runs in the same process as the native UI and is not a sandbox boundary.
