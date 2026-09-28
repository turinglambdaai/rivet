#lang scribble/manual

@(require (for-label (except-in racket/base sha256-bytes)
                     racket/contract/base
                     rivet
                     rivet/distribution
                     rivet/system))

@title[#:tag "rivet"]{Rivet: First-Party Native Desktop Applications with Racket}
@author{turinglambdaai}

Rivet is a native desktop application foundation that keeps application logic
in Racket while using WinUI 3 on Windows and SwiftUI/AppKit on macOS. It embeds
Racket CS in the native process and generates typed native clients from Racket
RPC, event, and state declarations. Rivet is not a WebView wrapper and does not
introduce a cross-platform widget DSL.

@section{Installation}

Install the published package with the @exec{raco} executable from the Racket
CS installation that applications should embed:

@commandline{raco pkg install --auto rivet}

Create and run a starter application:

@commandline{raco rivet new hello}
@commandline{cd hello}
@commandline{raco rivet doctor}
@commandline{raco rivet dev}

The generated project contains a Racket backend plus the current platform's
first-party native host. Use @exec{raco rivet doctor} before the first native
build to identify missing platform tools.

@section{Architecture and Module Boundaries}

The public libraries are deliberately split into three layers:

@itemlist[
 @item{@racketmodname[rivet] defines application RPCs, events, shared state,
       RVT1 framing, and the embedded backend server.}
 @item{@racketmodname[rivet/system] provides opt-in operating-system services
       through a native adapter installed by the WinUI or AppKit host.}
 @item{@racketmodname[rivet/distribution] provides opt-in release and update
       primitives. It is independent of RVT1 and the embedded runtime
       lifecycle.}]

Requiring @racketmodname[rivet] does not eagerly load the system or
distribution layers.

@section{Application Backend}

@defmodule[rivet]

@subsection{RPCs, Events, and State}

@defstruct*[rivet-type ([name symbol?])]{Represents a public schema type descriptor.}

@defthing[Void rivet-type?]
@defthing[Bool rivet-type?]
@defthing[Int64 rivet-type?]
@defthing[String rivet-type?]
@defthing[Bytes rivet-type?]
@defthing[List rivet-type?]

@defstruct*[state-info
            ([name symbol?]
             [type any/c]
             [cell box?]
             [lock semaphore?])]{
Represents a registered shared state value. Applications normally create one
with @racket[define-state] instead of calling the constructor directly.}

@defform[(define-rpc (name [arg : type] ... : result-type) body ...)]{
Defines a Racket procedure named @racket[name] and registers it as an RPC for
generated Swift and C++ clients. Supported schema types are @racket[String],
@racket[Int64], @racket[Bool], @racket[Bytes], @racket[Void], @racket[Any],
@racket[(List type)], and @racket[(Optional type)]. The result is validated
before it is placed on the wire.}

@defform[(define-event name : type)]{
Registers an event and defines @racket[name] as a one-argument procedure that
emits a validated event value while a Rivet server is active. Omitting the type
uses @racket[Any]. Event payloads cannot have type @racket[Void].}

@defform[(define-state name : type initial-value)]{
Creates and registers a shared state value. Native clients can read and set the
state through generated APIs, and successful changes emit Rivet's reserved
state event. State values cannot have type @racket[Void].}

@defproc[(emit-event! [name (or/c symbol? string?)] [value any/c]) void?]{
Emits an already registered event value on the active server connection. The
procedure reports an error when no server is active on the current thread.}

@defproc[(state-ref [state state-info?]) any/c]{Returns the current state value.}

@defproc[(state-set! [state state-info?] [value any/c]) void?]{
Validates and atomically commits a state value, then admits its native event in
the same update order.}

@racketblock[
(require rivet)

(define-rpc (greet [name : String] : String)
  (string-append "Hello, " name))

(define-event notification : String)
(define-state signed-in? : Bool #f)]

@subsection{Serving an Embedded Connection}

@defproc[(serve [in input-port?]
                [out output-port?]
                [#:max-pending-requests max-pending-requests exact-positive-integer? 1024]
                [#:max-outgoing-frames max-outgoing-frames exact-positive-integer? 64])
         void?]{
Runs the RVT1 backend over binary ports. Requests execute concurrently within
the configured bound, while outgoing responses and events use bounded
backpressure.}

@defproc[(serve-fds [input-fd exact-integer?]
                    [output-fd exact-integer?]
                    [#:max-pending-requests max-pending-requests exact-positive-integer? 1024]
                    [#:max-outgoing-frames max-outgoing-frames exact-positive-integer? 64])
         void?]{
Adapts native file descriptors to binary ports and calls @racket[serve].}

@defproc[(rpc-schema) list?]{Returns the registered RPC schema used by code generation.}
@defproc[(event-schema) list?]{Returns the registered event schema.}
@defproc[(state-schema) list?]{Returns the registered state schema.}

@section{System Services}

@defmodule[rivet/system]

The generated native host installs a @racket[system-adapter] during startup.
Headless tools and tests may parameterize @racket[current-system-adapter] with
a deterministic adapter. The default adapter fails closed instead of silently
pretending that an operating-system action succeeded.

@defstruct*[system-adapter
            ([name symbol?]
             [capabilities list?]
             [acquire-single-instance procedure?]
             [register-activation-handler procedure?]
             [show-notification procedure?]
             [set-tray-menu procedure?]
             [set-autostart procedure?]
             [autostart-enabled procedure?]
             [secure-store-set procedure?]
             [secure-store-ref procedure?]
             [secure-store-remove procedure?]
             [install-crash-hook procedure?])]{
Defines the operations supplied by a first-party native host or a test double.}

@defparam[current-system-adapter adapter system-adapter?]{
The adapter used by all system-service convenience procedures.}

@defstruct*[settings-store
            ([path path?]
             [lock semaphore?]
             [data hash?])
            #:mutable]{
Represents one synchronized, JSON-backed preferences file.}

@defparam[current-rivet-log-sink sink procedure?]{
Receives each structured log record. The default writes JSON to the current
error port.}

@defparam[current-rivet-crash-reporter reporter procedure?]{
Receives a structured crash record and its exception. The default is a no-op.}

@defproc[(system-capabilities) list?]{Returns capability symbols advertised by the active adapter.}
@defproc[(acquire-single-instance! [application-id string?] [activation any/c]) any/c]{
Acquires the application instance lock or forwards activation data to the
existing instance, according to the native adapter.}
@defproc[(register-activation-handler! [handler procedure?]) any/c]{
Registers the handler for deep links, file associations, and forwarded
secondary-instance activation.}
@defproc[(show-system-notification! [title string?]
                                    [body string?]
                                    [#:tag tag (or/c #f string?) #f]) any/c]{
Displays an operating-system notification.}
@defproc[(set-tray-menu! [items list?]) any/c]{Configures a Windows tray or macOS menu-bar menu.}
@defproc[(set-autostart! [enabled? boolean?]) any/c]{Enables or disables login startup.}
@defproc[(autostart-enabled?) boolean?]{Reports the current login-startup state.}
@defproc[(secure-store-set! [service string?] [account string?] [secret bytes?]) any/c]{
Stores a secret through Windows Credential Manager or macOS Keychain.}
@defproc[(secure-store-ref [service string?] [account string?] [default any/c #f]) any/c]{
Reads a secret, returning @racket[default] when no value is present.}
@defproc[(secure-store-remove! [service string?] [account string?]) any/c]{Removes a stored secret.}

@subsection{Settings and Diagnostics}

@defproc[(make-settings-store [path path-string?]) settings-store?]{
Loads an atomic JSON-backed settings store.}
@defproc[(settings-ref [store settings-store?] [key (or/c symbol? string?)] [default any/c #f]) any/c]{
Reads a setting.}
@defproc[(settings-set! [store settings-store?] [key (or/c symbol? string?)] [value any/c]) any/c]{
Persists a setting using atomic file replacement.}
@defproc[(settings-remove! [store settings-store?] [key (or/c symbol? string?)]) void?]{
Removes a persisted setting.}
@defproc[(settings-snapshot [store settings-store?]) hash?]{Returns the current immutable settings hash.}

@defproc[(rivet-log [level (or/c 'debug 'info 'warning 'error 'critical)]
                    [event any/c]
                    [#:fields fields hash? (hasheq)])
         hash?]{
Sends a structured record to @racket[current-rivet-log-sink] and returns it.}
@defproc[(call-with-crash-reporting [thunk (-> any/c)]
                                    [#:context context hash? (hasheq)]) any/c]{
Reports an uncaught Racket exception through
@racket[current-rivet-crash-reporter], then re-raises it.}

@section{Distribution and Secure Updates}

@defmodule[rivet/distribution]

The updater treats HTTPS as transport protection, not as its root of trust.
Manifests are independently signed with Ed25519 and bind the application ID,
version, channel, rollout, rollback policy, artifact byte size, SHA-256 digest,
platform, and architecture.

@defstruct*[update-artifact
            ([platform symbol?]
             [architecture symbol?]
             [url string?]
             [sha256 string?]
             [size exact-nonnegative-integer?]
             [installer symbol?]
             [arguments (listof string?)])]{
Describes one installer artifact bound into the signed manifest.}

@defstruct*[update-manifest
            ([application-id string?]
             [version string?]
             [build exact-positive-integer?]
             [channel symbol?]
             [published-at string?]
             [minimum-version string?]
             [previous-version (or/c #f string?)]
             [rollback-allowed? boolean?]
             [rollout exact-nonnegative-integer?]
             [artifacts (listof update-artifact?)])]{
Represents the parsed payload covered by an Ed25519 signature.}

@defstruct*[updater-config
            ([application-id string?]
             [current-version string?]
             [channel symbol?]
             [platform symbol?]
             [architecture symbol?]
             [public-key any/c]
             [expected-key-id (or/c #f string?)]
             [rollout-bucket exact-nonnegative-integer?]
             [maximum-download-bytes exact-positive-integer?])]{
Holds local identity, trust, rollout, and resource-limit policy.}

@defstruct*[update-candidate
            ([manifest update-manifest?]
             [artifact update-artifact?])]{
Pairs an accepted manifest with its current-platform artifact.}

@defstruct*[install-plan
            ([candidate update-candidate?]
             [downloaded-path path-string?]
             [backup-path (or/c #f path-string?)]
             [install procedure?]
             [restart procedure?]
             [rollback procedure?])]{
Contains the verified artifact and platform-owned lifecycle callbacks.}

@subsection{Versions and Channels}

@defproc[(version? [value any/c]) boolean?]{Recognizes SemVer 2.0 version strings.}
@defproc[(version-compare [left string?] [right string?]) (or/c -1 0 1)]{
Compares SemVer precedence; build metadata does not affect the result.}
@defproc[(valid-channel? [value any/c]) boolean?]{Recognizes @racket['stable], @racket['beta], and @racket['dev].}
@defproc[(channel-accepts-version? [channel symbol?] [version string?]) boolean?]{
Checks whether a version is allowed by a release channel.}

@subsection{Signed Manifests}

@racket[update-artifact] values describe one platform artifact using the fields
@racket[platform], @racket[architecture], @racket[url], @racket[sha256],
@racket[size], @racket[installer], and @racket[arguments].
@racket[update-manifest] values contain the signed application and release
policy plus a list of artifacts.

@defproc[(write-signed-manifest [manifest update-manifest?]
                                [private-key any/c]
                                [key-id string?]
                                [out output-port? (current-output-port)])
         void?]{
Validates, serializes, and signs a manifest payload with Ed25519.}
@defproc[(verify-signed-manifest [input input-port?]
                                 [public-key any/c]
                                 [#:key-id expected-key-id (or/c #f string?) #f])
         update-manifest?]{
Verifies the exact signed payload before exposing the parsed manifest.}

@subsection{Selecting and Installing an Update}

An @racket[updater-config] records the application ID, current version,
channel, platform, architecture, public key, expected key ID, deterministic
rollout bucket, and maximum download size.

@defproc[(fetch-update-manifest [manifest-url string?]
                                [public-key any/c]
                                [#:key-id key-id (or/c #f string?) #f]
                                [#:maximum-bytes maximum-bytes exact-positive-integer? (* 1024 1024)])
         update-manifest?]{
Downloads a bounded manifest from HTTPS and verifies its Ed25519 signature.}
@defproc[(select-update [config updater-config?] [manifest update-manifest?])
         (or/c #f update-candidate?)]{
Applies identity, channel, version, minimum-version, rollout, platform, and
architecture policy.}
@defproc[(download-update [config updater-config?]
                          [candidate update-candidate?]
                          [destination path-string?])
         path?]{
Downloads to a partial file, enforces the signed size and configured bound,
verifies SHA-256, and atomically moves the verified artifact into place.}
@defproc[(execute-install-plan! [plan install-plan?]) any/c]{
Runs the native installation and restart callbacks. If installation fails and
the signed policy allows rollback, the rollback callback runs before the
exception is re-raised.}

@section{Command-Line Workflow}

@verbatim{
raco rivet new <name>       create a native starter project
raco rivet doctor           inspect the native toolchain
raco rivet dev              build and run the current application
raco rivet build            compile backend and native host
raco rivet package          create and verify a distributable
raco rivet release          build installer, signed update manifest, and SBOM
raco rivet verify           verify an existing packaged artifact
raco rivet compliance       generate SBOM and third-party notices
}

Production application releases require publisher-controlled platform signing
credentials and a separate Ed25519 update-signing key. Secrets must be supplied
through the documented release environment and must not be committed to an
application or to Rivet.

@section{Further Reading}

The source repository contains the full getting-started guides, architecture,
RVT1 protocol specification, runtime limits, production signing guide, system
services guide, and release/update threat model. See
@url{https://github.com/turinglambdaai/rivet}.
