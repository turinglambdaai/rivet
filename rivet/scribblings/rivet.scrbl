#lang scribble/manual

@(require (for-label (except-in racket/base sha256-bytes)
                     racket/contract/base
                     rivet
                     rivet/distribution
                     rivet/protocol
                     rivet/resources
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

The public libraries are deliberately split into four explicit boundaries:

@itemlist[
 @item{@racketmodname[rivet] defines application RPCs, events, shared state,
       RVT1 framing, and the embedded backend server.}
 @item{@racketmodname[rivet/keel] projects Rivet declarations into the shared,
       transport-neutral Keel application schema.}
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

State descriptors and the registry records behind RPCs, Events, Records, and
Enums are intentionally opaque. Applications declare them with the forms in
this section; code generators consume the immutable @racket[backend-schema]
snapshot instead of depending on mutable runtime representation.

The type names in declarations are schema grammar, not Racket variables or
runtime descriptor values. They are interpreted only inside the declaration
forms below. This keeps application code honest: use ordinary Racket
predicates and contracts for runtime values, and use the generated Keel schema
when a tool needs to inspect the application contract.

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

@subsection{Keel Schema Projection}

@defmodule[rivet/keel]

Keel is the transport-neutral application contract shared by Rivet and Glaze.
These adapters expose the same application model without moving RVT1 framing,
native client generation, embedding, or UI ownership out of Rivet.

@defproc[(backend-schema->app-schema [schema hash?]
                                     [#:id id string?]
                                     [#:revision revision exact-nonnegative-integer? 1])
         any/c]{
Converts an immutable @racket[backend-schema] snapshot into a validated Keel
@racketidfont{app-schema?}. Rivet @racket[Void] maps to Keel
@racketidfont{Unit}, @racket[Any] to @racketidfont{Value}, and named Records
and Enums to references. RVT1 v1 Error frames
carry diagnostic strings rather than typed application errors, so projected
commands intentionally publish an empty error-code list.
}

@defproc[(current-backend-app-schema [#:id id string?]
                                     [#:revision revision exact-nonnegative-integer? 1])
         any/c]{
Projects the declarations currently registered in the backend.
}

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

@defparam[current-rivet-diagnostic-sink sink procedure?]{
Receives each structured diagnostic record emitted by the backend. The
default discards records: embedded desktop processes do not necessarily own
a console, and the first stderr write from a Windows GUI-subsystem process
can allocate a visible console window. Applications that want backend
diagnostics install a sink backed by their structured logger; records use
the @tt{rivet.diagnostic.v1} schema.}

@defproc[(backend-schema) hash?]{Returns one immutable, data-only snapshot with
@racket['rpcs], @racket['events], @racket['states], @racket['records], and
@racket['enums] entries. This is the supported reflection boundary for code
generation and tooling; registry structs and mutable State cells are private.}

@defproc[(rpc-schema) list?]{Returns the registered RPC schema used by code generation.}
@defproc[(event-schema) list?]{Returns the registered event schema.}
@defproc[(state-schema) list?]{Returns the registered state schema.}
@defproc[(record-schema) list?]{Returns the registered Record schema.}
@defproc[(enum-schema) list?]{Returns the registered Enum schema.}

@subsection{RVT1 Framing and the Value Codec}

@defmodule[rivet/protocol]

Applications normally reach the wire through @racket[serve] and generated
clients. This module is the framing layer underneath: it is public because
debuggers, protocol fuzzers, and alternative transports consume exactly the
same bytes, and because the transport limits are the contract between an
application backend and its host.

Every frame carries the @tt{RVT1} magic, the protocol version, a message
type, an unsigned 64-bit identifier, and a payload. Payloads use a small
tagged value codec that covers the RVT1 value grammar; framing and the
value codec are independent so later grammar revisions cannot change
transport semantics.

@defstruct*[frame ([type exact-integer?]
                   [id exact-nonnegative-integer?]
                   [payload bytes?])]
           #:transparent] {
One wire frame. @racket[type] is one of the @racket[message:]hello
through @racket[message:shutdown] constants, and @racket[id] ranges from
@racket[0] through @math{2^64-1}.}

@defproc[(write-frame [f frame?]
                      [out output-port? (current-output-port)])
         void?]{
Validates the message type, identifier, and payload length, then writes the
frame. Overlong payloads and out-of-range identifiers are rejected before
any bytes reach the port.}

@defproc[(read-frame [in input-port? (current-input-port)])
         (or/c frame? eof-object?)]{
Reads exactly one frame, validating its version, type, identifier, and
payload length. Returns @racket[eof] at a clean stream boundary.}

@defproc[(encode-value [value any/c]) bytes?]{
Encodes one value using the RVT1 tagged value codec. Depth, node count, and
encoded size are bounded; use @racket[Bytes] instead of huge Lists for bulk
data, because a flat List inside one legal frame can still expand to far
more memory as decoded objects.}

@defproc[(decode-value [payload bytes?]) any/c]{
Decodes bytes produced by @racket[encode-value]. Malformed tags, excessive
depth, and excessive node counts are rejected instead of allocating.}

@defthing[protocol-version exact-nonnegative-integer? #:value 1]{
The RVT1 protocol version written into every frame and enforced on read.}

@defthing[max-frame-payload-size exact-nonnegative-integer? #:value 67108864]{
The largest accepted frame payload: 64 MiB.}

@defthing[max-value-depth exact-positive-integer? #:value 64]{
The maximum nesting depth accepted by the value codec.}

@defthing[max-value-nodes exact-positive-integer? #:value 262144]{
The maximum number of value nodes, including the root, decoded or encoded
per payload.}

@defthing[message:hello exact-positive-integer? #:value 1]{
The host greeting message type.}
@defthing[message:request exact-positive-integer? #:value 2]{
A client request; the identifier correlates it with a response.}
@defthing[message:response exact-positive-integer? #:value 3]{
A successful reply to a @racket[message:request].}
@defthing[message:error exact-positive-integer? #:value 4]{
A failure reply carrying a diagnostic string.}
@defthing[message:event exact-positive-integer? #:value 5]{
A backend-pushed event.}
@defthing[message:cancel exact-positive-integer? #:value 6]{
Cancels a pending request by identifier.}
@defthing[message:shutdown exact-positive-integer? #:value 7]{
Requests orderly backend shutdown.}

@subsection{Application Resources}

@defmodule[rivet/resources]

Locates the read-only application resource directory staged by the build.
The same API answers for development layouts, installed .app bundles,
MSI installs, and Linux prefix layouts, so backends never hardcode
platform resource paths.

@defparam[current-resource-root root (or/c #f path-string?)]{
Overrides resource discovery, for hosts with a non-standard layout. When
unset, @racket[resource-root] searches the locations derived from the
current executable.}

@defproc[(resource-root) path?]{
Returns the existing resource root, checking a configured or derived
location. Raises when no candidate directory exists, so a mis-staged
application fails at startup instead of at first use.}

@defproc[(resource-path [piece path-string?] ...) path?]{
Builds a path inside the resource root. Components must be relative and
must not contain @litchar{.} or @litchar{..} segments; traversal attempts
are rejected.}

@section{Real-Time Chart Series}

@defmodule[rivet/chart]

The chart data plane keeps time-series state on the Racket side and exports
it in the two shapes native chart widgets consume: the recent-window pull
(an ordinary typed RPC built from @racket[chart-series-window]) and the
high-rate append push (a @racket[bytes?] batch carried by an application
event). Samples are @racket[(cons timestamp-nanoseconds value)] pairs of
exact integers; Rivet's typed surface is integer-native by design, and
measurement domains (ns offsets, ps offsets, ppm drift) stay exact instead
of losing precision to floating point.

The batch layout is a cross-language contract with the portable C++ decoder
in @filepath{runtime/include/rivet/chart_batch.hpp} and the Swift decoder
in RivetUI; the three implementations are pinned by shared golden bytes in
their test suites. @secref["top"] links the full convention guide.

@defproc[(make-chart-series [id string?]
                            [#:capacity capacity exact-positive-integer? 16384])
         chart-series?]{
Creates a series ring buffer. Capacity is the retained sample count; when
the ring overflows, the oldest samples are evicted and the drop is reported
through @racket[chart-series-dropped] and through the next batch's absolute
first index.}

@defproc[(chart-series? [value any/c]) boolean?]{
Predicate for chart series values.}

@defproc[(chart-series-append! [series chart-series?]
                               [samples (listof (cons/c exact-nonnegative-integer?
                                                        exact-integer?))])
         void?]{
Appends @racket[(ts . value)] samples in order. Timestamps must be strictly
increasing within the call and against the series tail; a reordered feed
corrupts window slicing and host index accounting, so it raises instead of
silently reordering.}

@defproc[(chart-series-window [series chart-series?]
                              [span-ns (or/c #f exact-nonnegative-integer?)])
         (listof (cons/c exact-nonnegative-integer? exact-integer?))]{
Newest-last list of live samples no older than the newest timestamp minus
@racket[span-ns]; @racket[#f] returns the whole live ring. This is the
initial-paint and gap-recovery pull behind an ordinary typed RPC.}

@defproc[(chart-series-drain-batch! [series chart-series?]) bytes?]{
Returns one batch with every sample appended since the previous drain.
The header's absolute first index lets a host that fell behind detect ring
eviction and re-pull the window.}

@defproc[(chart-series-latest [series chart-series?])
         (or/c #f (cons/c exact-nonnegative-integer? exact-integer?))]{
The newest sample, or @racket[#f] when the series is empty.}

@defproc[(chart-series-count [series chart-series?]) exact-nonnegative-integer?]{
Number of live samples retained by the ring.}

@defproc[(chart-series-capacity [series chart-series?]) exact-positive-integer?]{
The ring capacity fixed at creation.}

@defproc[(chart-series-appended [series chart-series?]) exact-nonnegative-integer?]{
Total samples ever appended; the absolute index space hosts track.}

@defproc[(chart-series-dropped [series chart-series?]) exact-nonnegative-integer?]{
Live samples evicted from the ring before being drained.}

@defproc[(chart-series-id [series chart-series?]) string?]{
The series identifier hosts render against.}

@defproc[(chart-series-reset! [series chart-series?]) void?]{
Clears samples and the absolute index space.}

@defproc[(chart-batch-encode
          [samples (listof (cons/c exact-nonnegative-integer? exact-integer?))]
          [first-index exact-nonnegative-integer? 0])
         bytes?]{
Encodes samples as a chart batch: little-endian u32 magic, u32 count, i64
absolute first index, then count times (i64 timestamp-ns, i64 value).}

@defproc[(chart-batch-decode [batch bytes?])
         (values (listof (cons/c exact-nonnegative-integer? exact-integer?))
                 exact-nonnegative-integer?)]{
Decodes a chart batch, validating magic and declared lengths. Raises on
malformed input.}

@defproc[(chart-batch-sample-count [batch bytes?]) exact-nonnegative-integer?]{
The sample count declared in the batch header.}

@defproc[(chart-batch-first-index [batch bytes?]) exact-nonnegative-integer?]{
The absolute first index declared in the batch header.}

@defthing[chart-batch-magic exact-nonnegative-integer?]{
The RVC1 magic a decoder must verify before trusting a batch
(@racket[ #x52564331]).}

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

@defproc[(settings-store? [value any/c]) boolean?]{
Recognizes an opaque, synchronized JSON-backed preferences store. Its path,
lock, and cached data are private so updates cannot bypass the atomic public
operations. Transactions refresh under an in-process and operating-system
lock, and returned JSON trees are deeply immutable.}

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
@defproc[(set-tray-menu! [items list?]) any/c]{Configures a platform tray or menu-bar menu.}
@defproc[(set-autostart! [enabled? boolean?]) any/c]{Enables or disables login startup.}
@defproc[(autostart-enabled?) boolean?]{Reports the current login-startup state.}
@defproc[(secure-store-set! [service string?] [account string?] [secret bytes?]) any/c]{
Stores a secret through the platform credential service.}
@defproc[(secure-store-ref [service string?] [account string?] [default any/c #f]) any/c]{
Reads a secret, returning @racket[default] when no value is present.}
@defproc[(secure-store-remove! [service string?] [account string?]) any/c]{Removes a stored secret.}
@defproc[(install-crash-hook! [handler procedure?]) any/c]{
Installs the platform-native crash handler. When the process fails, the
handler receives a structured crash record; pair it with
@racket[current-rivet-crash-reporter] to route the Racket-side record the
same way.}

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

@defproc[(platform-installation? [value any/c]) boolean?]{
Recognizes an opaque first-party portable replacement transaction. Its plan,
health and commit callbacks, and target-scoped lock identity remain private so
callers cannot bypass the installation invariants.}

@subsection{Versions and Channels}

@defproc[(version? [value any/c]) boolean?]{Recognizes SemVer 2.0 version strings.}
@defproc[(version-compare [left string?] [right string?]) (or/c -1 0 1)]{
Compares SemVer precedence; build metadata does not affect the result.}
@defproc[(version<? [left string?] [right string?]) boolean?]{
Reports SemVer precedence; equivalent to a negative
@racket[version-compare] result.}
@defproc[(version<=? [left string?] [right string?]) boolean?]{SemVer @math{<=}.}
@defproc[(version=? [left string?] [right string?]) boolean?]{SemVer equality by precedence.}
@defproc[(version>=? [left string?] [right string?]) boolean?]{SemVer @math{>=}.}
@defproc[(version>? [left string?] [right string?]) boolean?]{SemVer @math{>}.}
@defproc[(valid-channel? [value any/c]) boolean?]{Recognizes @racket['stable], @racket['beta], and @racket['dev].}
@defproc[(channel-accepts-version? [channel symbol?] [version string?]) boolean?]{
Checks whether a version is allowed by a release channel.}

@subsection{Signed Manifests}

@racket[update-artifact] values describe one platform artifact using the fields
@racket[platform], @racket[architecture], @racket[url], @racket[sha256],
@racket[size], @racket[installer], and @racket[arguments].
@racket[update-manifest] values contain the signed application and release
policy plus a non-empty list of artifacts. The minimum updatable version and
optional rollback predecessor must both be older than the release version.
Artifact sizes are positive, and a manifest cannot repeat the same platform,
architecture, and installer identity. Payloads and signed wrappers contain
exactly one JSON value and reject fields outside their versioned schema, so a
publisher typo cannot be silently ignored.

@defproc[(write-signed-manifest [manifest update-manifest?]
                                [private-key any/c]
                                [key-id string?]
                                [out output-port? (current-output-port)])
         void?]{
Validates, serializes, and signs a manifest payload with Ed25519.}
@defproc[(read-signed-manifest [input input-port?])
         (values update-manifest? bytes? string? bytes?)]{
Decodes a signed wrapper for inspection and returns its parsed manifest, exact
payload bytes, key ID, and signature bytes. This procedure does not
authenticate them; update clients should use @racket[verify-signed-manifest].}
@defproc[(verify-signed-manifest [input input-port?]
                                 [public-key any/c]
                                 [#:key-id expected-key-id (or/c #f string?) #f])
         update-manifest?]{
Verifies the expected key ID and Ed25519 signature over the exact payload bytes
before parsing or exposing the manifest.}

@defthing[manifest-schema-version exact-positive-integer? #:value 1]{
The versioned schema tag carried by every manifest payload.}

@defproc[(manifest->payload-bytes [manifest update-manifest?]) bytes?]{
Serializes a manifest into the exact canonical payload bytes a signature
covers. Publishers sign these bytes; there is no second serialization.}

@defproc[(payload-bytes->manifest [payload bytes?]) update-manifest?]{
Parses canonical payload bytes into a manifest. The closed schema rejects
unknown fields, trailing JSON values, and contradictory policy, whether or
not the payload was authenticated.}

@subsection{Key and Digest Primitives}

The same primitives the updater uses, exposed for release tooling and
tests. Keys are Racket @racket[crypto] key values; readers accept the
standard DER encodings (SubjectPublicKeyInfo, OneAsymmetricKey,
PrivateKeyInfo) and Rivet's textual forms.

@defproc[(read-ed25519-public-key [path path-string?]) any/c]{
Reads and validates an Ed25519 public key from a file.}
@defproc[(read-ed25519-private-key [path path-string?]) any/c]{
Reads and validates an Ed25519 private key from a file.}
@defproc[(bytes->ed25519-public-key [raw bytes?]) any/c]{
Decodes an embedded public key from bytes, the form release builds embed
in application source.}
@defproc[(ed25519-sign [private-key any/c] [message bytes?]) bytes?]{
Signs @racket[message] with Ed25519 and returns the 64-byte signature.}
@defproc[(ed25519-verify [public-key any/c]
                         [message bytes?]
                         [signature bytes?])
         boolean?]{
Verifies an Ed25519 signature; @racket[#f] for any malformed signature.}
@defproc[(sha256-bytes [input bytes?]) bytes?]{
Returns the raw SHA-256 digest of a byte string.}
@defproc[(sha256-file [path path-string?]) bytes?]{
Returns the raw SHA-256 digest of a file's exact bytes.}
@defproc[(sha256-file/hex [path path-string?]) string?]{
Returns the lowercase hexadecimal SHA-256 digest of a file, the form signed
manifests carry.}
@defproc[(bytes->base64-string [value bytes?]) string?]{
Standard base64 encoding, used by signed wrappers and embedded keys.}
@defproc[(base64-string->bytes [value string?]) bytes?]{
Decodes standard base64, raising on malformed input.}

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
                          [destination path-string?]
                          [#:on-progress on-progress procedure? void]
                          [#:progress-every progress-every
                           (or/c #f exact-positive-integer?) #f])
         path?]{
Downloads to a partial file, enforces the signed size and configured bound,
verifies SHA-256, and atomically moves the verified artifact into place.
@racket[on-progress] receives cumulative downloaded bytes, starting at zero
and ending at the downloaded size. Intermediate reports are throttled to about
one per percent of the signed artifact size. The callback runs synchronously
on the downloading thread and should quickly dispatch or record UI work. A
final byte count reports transfer progress, not successful verification.
Pass @racket[progress-every] to select a byte cadence; @racket[#f] uses the
one-percent default. Small cadences are appropriate for an activity watchdog,
not direct UI rendering.}

@defproc[(verify-update-artifact! [candidate update-candidate?] [path path-string?])
         path-string?]{
Checks the downloaded file's byte size and SHA-256 digest against the signed
manifest and returns @racket[path]. Used by custom install flows;
@racket[download-update] already applies it before moving a verified
artifact into place.}

@defproc[(make-install-plan [candidate update-candidate?]
                            [downloaded-path path-string?]
                            [#:backup-path backup-path (or/c #f path-string?) #f]
                            [#:install install procedure?]
                            [#:restart restart procedure? void]
                            [#:rollback rollback procedure? void])
         install-plan?]{
Builds the plan consumed by @racket[execute-install-plan!] for
product-specific native installers. Rivet's portable adapter constructs its
own plan through @racket[prepare-platform-installation].}

@subsection{Managed Check and Download Lifecycle}

@defproc[(current-update-architecture) (or/c 'x64 'arm64)]{
Returns the architecture symbol used by Rivet release manifests.}

@defproc[(make-updater
          [#:application-id application-id string?]
          [#:current-version current-version string?]
          [#:channel channel (or/c 'stable 'beta 'dev) 'stable]
          [#:platform platform
           (or/c 'windows 'macos 'linux) (current-update-platform)]
          [#:architecture architecture
           (or/c 'x64 'arm64) (current-update-architecture)]
          [#:install-kind install-kind
           (or/c #f 'portable 'appimage 'package-manager) #f]
          [#:public-key public-key any/c]
          [#:key-id key-id string?]
          [#:manifest-url manifest-url string?]
          [#:data-directory data-directory path-string?]
          [#:rollout-bucket rollout-bucket (integer-in 0 99)]
          [#:maximum-manifest-bytes maximum-manifest-bytes
           exact-positive-integer? (* 1024 1024)]
          [#:maximum-download-bytes maximum-download-bytes
           exact-positive-integer? (* 512 1024 1024)]
          [#:check-timeout check-timeout (and/c real? positive?) 30.0]
          [#:stall-timeout stall-timeout (and/c real? positive?) 120.0]
          [#:total-timeout total-timeout
           (and/c real? positive?) (* 30.0 60.0)])
         updater?]{
Creates an opaque updater that centralizes signed-manifest checking, candidate
selection, bounded background download, progress, cancellation, and terminal
state. @racket[public-key] may be a parsed Ed25519 key or DER bytes, which are
decoded lazily during the first check. @racket[rollout-bucket] must be a stable
per-installation value from 0 through 99; do not choose a new random value on
each check. Unsupported platforms and architectures fail at construction
instead of silently selecting the wrong artifact. Installation and restart
remain owned by the native host or platform adapter.}

@defproc[(updater? [value any/c]) boolean?]{
Recognizes an updater created by @racket[make-updater].}

@defproc[(updater-check! [instance updater?]) hash?]{
Synchronously fetches and authenticates the manifest under
@racket[check-timeout], selects the matching candidate, and returns a JSON-safe
immutable result whose @racket['status] is @racket["available"],
@racket["up-to-date"], or @racket["error"].}

@defproc[(updater-download! [instance updater?]) void?]{
Starts the selected download on one background worker. A second check or
download is rejected while an operation is active. Byte activity is monitored
independently from UI percentage changes; exceeding the no-progress or total
deadline interrupts the worker, removes its partial file, and publishes an
error state.}

@defproc[(updater-cancel! [instance updater?]) boolean?]{
Requests cancellation of an active download. Returns @racket[#t] when a worker
was interrupted and @racket[#f] when no download was active.}

@defproc[(updater-state [instance updater?]) hash?]{
Returns an immutable, synchronized, JSON-safe snapshot with phase, percent,
message, downloaded path, available version, and current version fields.
Contained strings and JSON collections are immutable as well as the top-level
hash. The stable phase vocabulary is @racket["idle"], @racket["checking"],
@racket["available"], @racket["up-to-date"], @racket["downloading"],
@racket["downloaded"], @racket["cancelled"], and @racket["error"]. A failed
or cancelled download retains its authenticated candidate so an application
may explicitly retry; starting a new check resets it.}

@defproc[(updater-wait [instance updater?]
                       [timeout (or/c #f (and/c real? (not/c negative?))) #f])
         (or/c #f hash?)]{
Waits for the active download and returns its terminal snapshot. Returns
@racket[#f] when a finite timeout expires.}

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

@defproc[(current-install-kind [executable (or/c #f path-string?)
                                              (find-system-path 'run-file)])
         (or/c 'portable 'appimage 'package-manager)]{
Classifies the running installation for artifact selection: AppImage builds
detect their @envvar{APPIMAGE} environment, deb and rpm installations
resolve under @filepath{/opt} or @filepath{/usr}, and everything else is
portable. On Windows and macOS this always reports @racket['portable].
Pass @racket[#:install-kind] from this procedure to
@racket[select-update] or @racket[make-updater] so a machine never selects
a payload its installation cannot own.}

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
commit callbacks. A backup is deleted only after health succeeds. Only one
thread or process may execute or recover an installation at a time; a
competing transaction fails before touching shared filesystem state.}

@defproc[(recover-platform-installation!
          [installation platform-installation?]
          [journal-path path-string?])
         (or/c 'committed 'rolled-back)]{
Recovers the exact prepared replacement. Interrupted commits are repeated;
earlier phases restore the previous payload when signed policy permits it. The
same installation-scoped lock used by execution protects recovery.}

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
