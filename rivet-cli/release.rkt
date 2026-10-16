#lang racket/base

(require file/glob
         file/zip
         racket/file
         racket/list
         racket/path
         racket/string
         "../rivet/distribution/crypto.rkt"
         "../rivet/distribution/identity.rkt"
         "../rivet/distribution/manifest.rkt"
         "appimage.rkt"
         "compliance.rkt"
         "installer.rkt"
         "package.rkt"
         "project.rkt"
         "release-layout.rkt"
         "verify.rkt")

(provide release-project!
         release-update-environment
         portable-zip-path
         create-portable-zip!
         release-update-artifacts
         parse-update-payload-spec)

(define (required-environment name)
  (define value (getenv name))
  (unless (and value (not (string=? (string-trim value) "")))
    (error 'release-project! "required environment variable ~a is not set" name))
  (string-trim value))

(struct update-environment (base-url private-key key-id) #:transparent)

(define (release-update-environment updates?)
  (and updates?
       (update-environment
        (required-environment "RIVET_UPDATE_BASE_URL")
        (string->path (required-environment "RIVET_UPDATE_PRIVATE_KEY"))
        (required-environment "RIVET_UPDATE_KEY_ID"))))

;; Portable zip beside the installer: the family update feed consumes
;; it and it runs on locked-down machines. Deterministic input tree,
;; family naming <name>-<version>-<os>-<arch>.zip, sha256 alongside.
(define (create-portable-zip! project package)
  (define zip-path (portable-zip-path project))
  (when (file-exists? zip-path) (delete-file zip-path))
  (parameterize ([current-directory (path-only package)])
    (zip zip-path (path->string (file-name-from-path package))))
  (call-with-output-file (string-append (path->string zip-path) ".sha256")
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "~a  ~a~n"
              (sha256-file/hex zip-path)
              (path->string (file-name-from-path zip-path)))))
  zip-path)

(define (update-artifact-for-file update-config payload platform architecture installer)
  (update-artifact
   platform
   architecture
   (string-append
    (string-trim (update-environment-base-url update-config) "/")
    "/"
    (path->string (file-name-from-path payload)))
   (sha256-file/hex payload)
   (file-size payload)
   installer
   '()
   #f))

(define (portable-update-artifact update-config portable-zip)
  (update-artifact-for-file update-config portable-zip
                            (release-platform) (release-architecture) 'zip))

(define (release-update-artifact update-config project portable-zip
                                 #:platform [platform (release-platform)]
                                 #:architecture [architecture (release-architecture)])
  ;; AppImage is the Linux self-replacing format. When a release produces one,
  ;; make it the signed update payload rather than asking products to derive an
  ;; unsigned sibling URL from the portable ZIP or tarball name.
  (define appimage? (and (eq? platform 'linux)
                         (member "appimage" (project-linux-formats project))))
  (define payload (if appimage? (appimage-installer-path project) portable-zip))
  (unless (file-exists? payload)
    (raise-arguments-error 'release-project!
                           "selected update payload was not produced"
                           "installer" (if appimage? 'appimage 'zip)
                           "payload" payload))
  (update-artifact-for-file update-config payload platform architecture
                            (if appimage? 'appimage 'zip)))

;; A single signed feed serves both installation shapes on platforms where
;; Rivet owns both. Portable installs select the zip; MSI installs select the
;; MSI and hand it to the shared Windows handoff; AppImage installs select the
;; self-replacing image. macOS's host client intentionally consumes the zip —
;; the DMG remains the human installer.
;;
;; Products that publish additional update payloads per platform (a CLI next
;; to the app, a tar.gz instead of the zip) declare them with
;; `--update-payload <installer>:<glob>[:<component>]`, repeatable. Globs
;; expand relative to the project root; each match joins the feed with the
;; component discriminator, and a triple without a component keeps the
;; legacy shape.
(define (parse-update-payload-spec who spec)
  (define parts (string-split spec ":"))
  (unless (and (>= (length parts) 2) (<= (length parts) 3))
    (raise-arguments-error who
                           "--update-payload expects <installer>:<glob>[:<component>]"
                           "value" spec))
  (define installer (string->symbol (list-ref parts 0)))
  (unless (memq installer '(zip msi deb rpm appimage))
    (raise-arguments-error who
                           "update payload installer must be zip, msi, deb, rpm, or appimage"
                           "value" spec))
  (define component
    (and (= (length parts) 3)
         (let ([name (string->symbol (list-ref parts 2))])
           (unless (memq name '(app cli tool))
             (raise-arguments-error who
                                    "update payload component must be app, cli, or tool"
                                    "value" spec))
           name)))
  (values installer (list-ref parts 1) component))

(define (expand-update-payloads update-config project platform architecture specs)
  (append*
   (for/list ([spec (in-list specs)])
     (define-values (installer pattern component)
       (parse-update-payload-spec 'release-project! spec))
     (define matches
       (sort (glob (project-path project pattern)) path<?))
     (when (null? matches)
       (raise-arguments-error 'release-project!
                              "update payload pattern matched no files"
                              "pattern" pattern))
     (for/list ([path (in-list matches)])
       (define artifact
         (update-artifact-for-file update-config path platform architecture installer))
       (struct-copy update-artifact artifact [component component])))))

(define (release-update-artifacts update-config project portable-zip installer
                                  #:platform [platform (release-platform)]
                                  #:architecture [architecture (release-architecture)]
                                  #:extra-payloads [extra-payloads '()])
  (define portable
    (update-artifact-for-file update-config portable-zip
                              platform architecture 'zip))
  (define native
    (case platform
      [(windows)
       (and (file-exists? installer)
            (update-artifact-for-file update-config installer
                                      platform architecture 'msi))]
      [(linux)
       (define appimage? (member "appimage" (project-linux-formats project)))
       (define payload (and appimage? (appimage-installer-path project)))
       (and payload
            (file-exists? payload)
            (update-artifact-for-file update-config payload
                                      platform architecture 'appimage))]
      [else #f]))
  (append
   (list portable)
   (if native (list native) '())
   (expand-update-payloads update-config project platform architecture
                           extra-payloads)))

(define (cleanup-release-stage! package)
  (delete-directory/files package #:must-exist? #f))

(define (release-project! project
                          #:production? [production? #t]
                          #:updates? [updates? #t])
  ;; Linux production trust lives in the signed installer rather than
  ;; OS-level code signing, so the package itself is verified at development
  ;; strength and the released installer is production-verified below.
  (define linux-release? (eq? (system-type 'os) 'unix))
  (define package
    (package-project! project
                      #:production? (and production? (not linux-release?))))
  (define installer (create-installer! project package #:production? production?))
  ;; The portable zip rides beside every installer: the family update feed
  ;; consumes it, and it is the artifact users on locked-down machines can
  ;; still run. Same family naming as the installer, sha256 next to it.
  (define portable-zip (create-portable-zip! project package))
  (when (and production? linux-release?)
    ;; package-project! already performed the launch smoke. This second pass
    ;; adds Linux installer trust verification without opening the app twice.
    (verify-package! project package
                     #:production? #t
                     #:launch-smoke? #f))
  (define-values (sbom notices) (generate-compliance-artifacts! project))
  (define update-config (release-update-environment updates?))
  (define manifest-path
    (and
     update-config
     (let* ([previous (getenv "RIVET_PREVIOUS_VERSION")]
            [artifacts
             (release-update-artifacts update-config project portable-zip
                                       installer)]
            [manifest
             (update-manifest
              (project-identifier project)
              (project-version project)
              (project-build project)
              (project-release-channel project)
              (rfc3339-now)
              (or (getenv "RIVET_MINIMUM_UPDATABLE_VERSION") "0.0.0")
              (and previous (not (string=? previous "")) previous)
              #t
              (let ([configured (getenv "RIVET_UPDATE_ROLLOUT")])
                (if configured (string->number configured) 100))
              artifacts)]
            [path
             (project-path
              project "dist"
              (format "update-~a.json" (project-release-channel project)))])
       (call-with-output-file path
         #:exists 'truncate/replace
         (lambda (out)
           (write-signed-manifest
            manifest
            (read-ed25519-private-key
             (update-environment-private-key update-config))
            (update-environment-key-id update-config)
            out)))
       path)))
  ;; The unpacked payload (the .app, the <name>-<os>-<arch> tree) lives in
  ;; dist for the installer builders and the verify pass; a release should
  ;; leave only release artifacts behind. Delete it so the family-standard
  ;; artifact globs (`dist/<name>-*`) cannot sweep hundreds of runtime
  ;; megabytes into CI artifacts — the taskly 0.1.3 publish deadlock was
  ;; exactly that: two linux legs each shipped a <name>-linux-<arch>/ tree
  ;; and the gather step died merging them.
  (cleanup-release-stage! package)
  (values installer manifest-path sbom notices portable-zip))

(module+ test-support
  (provide portable-update-artifact
           release-update-artifact
           release-update-artifacts
           parse-update-payload-spec
           expand-update-payloads
           (struct-out update-environment)
           cleanup-release-stage!))
