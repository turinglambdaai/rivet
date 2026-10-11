#lang scribble/manual

@(require (for-label (except-in racket/base sha256-bytes)
                     racket/contract/base
                     rivet
                     rivet/distribution
                     rivet/system))

@title[#:tag "rivet"]{Rivet: First-Party Native Desktop Applications with Racket}
@author{turinglambdaai}

Rivet is a native desktop application foundation that keeps application logic
in Racket while using WinUI 3 on Windows, SwiftUI/AppKit on macOS, and GTK4 on
Linux. It embeds
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
@commandline{raco rivet inspect --json}
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

@section[#:tag "capability-sourcing"]{Finding and Integrating Missing Capabilities}

Rivet applications are not limited to modules implemented inside this
repository. Start with Racket's standard libraries and Package Catalog, then
choose the narrowest maintainable integration boundary:

@itemlist[
 @item{Use a maintained Racket package for portable application logic. Inspect
       installed packages with @exec{raco pkg show}, package metadata with
       @exec{raco pkg catalog-show --modules} and local documentation with
       @exec{raco docs}.}
 @item{Keep UI, lifecycle, accessibility, device, and operating-system services
       in the WinUI, SwiftUI/AppKit, or GTK native host.}
 @item{Use @tt{ffi/unsafe} behind a small checked Racket module when
       a stable C ABI requires frequent in-process calls. Explicitly own
       pointers, callbacks, threads, ABI checks, and native-library packaging.}
 @item{Use @racket[subprocess] or @racket[system*] for coarse-grained tools.
       Pass an executable and argument vector instead of constructing a shell
       command; add timeouts, bounded and concurrently drained output,
       cancellation, exit checks, version probes, packaging, and license
       verification.}
 @item{Reserve a sidecar for persistent or streaming runtimes, unstable ABIs,
       or required crash isolation. Own authentication, version negotiation,
       resource limits, lifecycle, recovery, distribution, and offline
       behavior.}]

Generated projects repeat this decision order in @filepath{AGENTS.md}, and
@exec{raco rivet inspect --json} exposes it as structured
@tt{capability-sourcing} data. Every external capability must also pass license,
Racket CS, platform/architecture, deterministic installation, failure-path,
packaged dependency-closure, and clean-machine checks.

@section{Application Backend}

@defmodule[rivet]

@subsection{RPCs, Events, State, Records, and Enums}

@defstruct*[rivet-type ([name symbol?])]{Represents a public schema type descriptor.}

@defthing[Void rivet-type?]
@defthing[Bool rivet-type?]
@defthing[Int64 rivet-type?]
@defthing[String rivet-type?]
@defthing[Bytes rivet-type?]
@defthing[List rivet-type?]

State descriptors and the registry records behind RPCs, Events, Records, and
Enums are intentionally opaque. Applications declare them with the forms in
this section; code generators consume the immutable @racket[backend-schema]
snapshot instead of depending on mutable runtime representation.

@defform[(define-rpc (name [arg : type] ... : result-type) body ...)]{
Defines a Racket procedure named @racket[name] and registers it as an RPC for
generated Swift, C++, and Kotlin clients. Supported schema types are @racket[String],
@racket[Int64], @racket[Bool], @racket[Bytes], @racket[Void], @racket[Any],
@racket[(List type)], @racket[(Optional type)], and names introduced by
@racket[define-record] or @racket[define-enum]. The result is validated before
it is placed on the wire.}

@defform[(define-record name ([field : field-type] ...))]{
Defines a constructor named @racket[name] and registers an ordered, typed
Record schema. Records generate Swift and C++ structs plus Kotlin data classes
and use an RVT1 List in field declaration order.}

@defproc[(record-ref [value any/c] [field (or/c symbol? string?)]) any/c]{
Returns a named field from a value constructed by @racket[define-record].}

@defform[(define-enum name (case ...))]{
Defines a constructor named @racket[name] and registers a closed, ordered set
of cases. The constructor accepts a case symbol or string. Generated Swift uses
a raw-value enum; generated C++ uses @tt{enum class}; generated Kotlin uses an
@tt{enum class} with the wire name; RVT1 carries the stable case name as a
String.}

@defproc[(enum-case [value any/c]) symbol?]{
Returns the case symbol from a value constructed by @racket[define-enum].}

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

@defproc[(state? [value any/c]) boolean?]{Reports whether @racket[value] is an
opaque State descriptor produced by @racket[define-state].}

@defproc[(state-ref [state state?]) any/c]{Returns the current state value.}

@defproc[(state-set! [state state?] [value any/c]) void?]{
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

@defproc[(backend-schema) hash?]{Returns one immutable, data-only snapshot with
@racket['rpcs], @racket['events], @racket['states], @racket['records], and
@racket['enums] entries. This is the supported reflection boundary for code
generation and tooling; registry structs and mutable State cells are private.}

@defproc[(rpc-schema) list?]{Returns the registered RPC schema used by code generation.}
@defproc[(event-schema) list?]{Returns the registered event schema.}
@defproc[(state-schema) list?]{Returns the registered state schema.}
@defproc[(record-schema) list?]{Returns the registered Record schema.}
@defproc[(enum-schema) list?]{Returns the registered Enum schema.}

@section{Application Identity}

@defmodule[rivet/app-info]

@defstruct*[app-info
            ([name string?]
             [display-name string?]
             [version string?]
             [build exact-positive-integer?]
             [identifier string?]
             [release-channel symbol?])]
            #:transparent] {
Represents the release identity staged from @filepath{rivet.rktd}.}

@defproc[(current-app-info) app-info?]{Reads and validates the identity for the running application.}
@defproc[(app-name) string?]{Returns the configured project name.}
@defproc[(app-display-name) string?]{Returns the user-visible application name.}
@defproc[(app-version) string?]{Returns the application release version.}
@defproc[(app-build) exact-positive-integer?]{Returns the application build number.}
@defproc[(app-identifier) string?]{Returns the application/bundle identifier.}
@defproc[(app-release-channel) symbol?]{Returns @racket['stable], @racket['beta], or @racket['dev].}

The build writes @filepath{rivet-app-info.rktd} into the application resource
root on every platform. The procedures fail explicitly when that generated
file is absent or malformed, so update checks cannot silently use a stale
hardcoded fallback.

@section{System Services}

@defmodule[rivet/system]

Generated native hosts call the first-party Swift/C++ system libraries
directly; they do not install Racket procedures across the RVT1 boundary.
Racket-side providers, headless tools, and tests may parameterize
@racket[current-system-adapter] with a deterministic adapter. The default
adapter fails closed instead of silently pretending that an operating-system
action succeeded.

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
Defines the operations supplied by a Racket-side provider or a test double.
Native hosts expose equivalent platform APIs in their native system library.}

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

@defstruct*[platform-installation
            ([plan install-plan?]
             [health-check procedure?]
             [commit procedure?])] {
Contains a first-party portable replacement plan plus its health and
idempotent commit callbacks. Applications normally pass this value to
@racket[execute-platform-installation!] rather than invoking the fields.}

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
@defproc[(execute-install-plan! [plan install-plan?]
                                [#:health-check health-check (-> any/c) (lambda () #t)]
                                [#:commit commit (-> any/c) void]
                                [#:journal-path journal-path (or/c #f path-string?) #f])
         any/c]{
Runs the native installation and restart callbacks, then requires
@racket[health-check] to return a true value before committing. The return
value is the restart callback's result, preserving the original procedure
contract. If any step fails and the signed policy allows rollback, the rollback
callback runs before the exception is re-raised.

When @racket[journal-path] is provided, every destructive phase is written to
an atomically replaced JSON journal. The restart callback must start the
replacement and return so the health check and commit can complete. Use an
absolute downloaded path and make rollback idempotent when durable recovery is
enabled.}

@defproc[(recover-install-plan! [plan install-plan?]
                                [journal-path path-string?]
                                [#:commit commit (-> any/c) void])
         (or/c 'committed 'rolled-back)]{
Recovers an interrupted journal for the exact same signed candidate, download,
and backup paths. A transaction already marked healthy commits; any other
unfinished phase rolls back when the signed manifest permits it. A mismatched
plan, malformed journal, forbidden rollback, or failed rollback is rejected
without deleting the evidence needed for diagnosis or another recovery
attempt.}

@subsection{First-Party Platform Replacement}

@defproc[(current-update-platform) (or/c 'windows 'macos 'linux)]{
Returns the update-platform symbol for the running operating system.}

@defproc[(platform-installer-policy [platform symbol?]
                                    [installer symbol?])
         (or/c 'portable 'package-manager 'unsupported)]{
Classifies the signed artifact. Portable ZIPs (and Linux AppImages) may use
Rivet's atomic replacement adapter. MSI, MSIX, DMG, PKG, deb, and rpm remain
owned by the native installer or package manager, so the portable adapter
will not silently bypass elevation, receipts, or repository policy.}

@defproc[(verify-platform-payload! [platform symbol?]
                                   [payload path-string?])
         void?]{
Applies the platform trust gate to a staged portable payload: Authenticode on
Windows, deep strict code-signature verification on macOS, and the already
verified signed-manifest size/SHA-256 boundary on Linux.}

@defproc[(prepare-platform-installation
          [candidate update-candidate?]
          [downloaded-path path-string?]
          [#:target target-path complete-path?]
          [#:restart restart procedure?]
          [#:health-check health-check procedure?]
          [#:verify-staged verify-staged (or/c #f procedure?) #f]
          [#:backup-path backup-path (or/c #f complete-path?) #f])
         platform-installation?]{
Builds a same-filesystem, atomic portable replacement. The verified archive
is staged and platform-verified before the old target moves. A durable marker
distinguishes first installation from replacement, so rollback is safe in
every interruption window. Target, download, and backup paths must be absolute
and distinct. The verifier override is intended for development artifacts and
tests; production callers should use the default fail-closed verifier.}

@defproc[(execute-platform-installation!
          [installation platform-installation?]
          [#:journal-path journal-path (or/c #f path-string?) #f])
         any/c]{
Executes the prepared replacement with its restart, health, rollback, and
commit callbacks. A backup is deleted only after health succeeds.}

@defproc[(recover-platform-installation!
          [installation platform-installation?]
          [journal-path path-string?])
         (or/c 'committed 'rolled-back)]{
Recovers the exact prepared replacement. Interrupted commits are repeated;
earlier phases restore the previous payload when signed policy permits it.}

@section{Command-Line Workflow}

@verbatim{
raco rivet new <name>       create a native starter project
raco rivet inspect --json   emit the agent-readable project contract
raco rivet doctor           inspect the native toolchain
raco rivet schema --json    emit the current versioned API schema
raco rivet schema --output rivet-schema.json
                             write a compatibility baseline
raco rivet schema check rivet-schema.json --json
                             reject breaking API changes
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
