#lang racket/base

;; First-party last-mile policy and atomic replacement for signed Rivet
;; updates. This module deliberately stays outside RVT1 and the embedded
;; runtime: an update is a distribution transaction, not an application RPC.

(require file/unzip
         racket/file
         racket/list
         racket/path
         racket/string
         racket/system
         "manifest.rkt"
         "updater.rkt")

(provide (struct-out platform-installation)
         current-update-platform
         current-install-kind
         platform-installer-policy
         verify-platform-payload!
         prepare-platform-installation
         execute-platform-installation!
         recover-platform-installation!)

(struct platform-installation (plan health-check commit) #:transparent)

(define (current-update-platform)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else
     (raise-arguments-error 'current-update-platform
                            "unsupported operating system"
                            "system-type" (system-type 'os))]))

(define (detect-install-kind platform executable appimage)
  (cond
    [(not (eq? platform 'linux)) 'portable]
    [(and appimage (not (string=? (string-trim appimage) ""))) 'appimage]
    [else
     (define raw
       (string-replace (if (path? executable)
                           (path->string executable)
                           executable)
                       "\\" "/"))
     (define normalized
       (if (string-prefix? raw "/")
           raw
           (string-replace
            (path->string (simplify-path (path->complete-path executable) #f))
            "\\" "/")))
     ;; Rivet's deb and rpm both install under /opt. /usr also covers products
     ;; following the conventional rpm layout. Update ownership matters here,
     ;; not which package database owns the executable.
     (if (or (string-prefix? normalized "/opt/")
             (string-prefix? normalized "/usr/"))
         'package-manager
         'portable)]))

(define (current-install-kind [executable (find-system-path 'run-file)])
  (detect-install-kind (current-update-platform) executable (getenv "APPIMAGE")))

;; `portable` means Rivet can replace the application payload itself.
;; `package-manager` means installation must remain under the OS transaction
;; owner; silently unpacking one of these artifacts would bypass elevation,
;; receipts, repository trust, and rollback policy.
(define (platform-installer-policy platform installer)
  (case platform
    [(windows)
     (case installer
       [(zip) 'portable]
       [(msi msix exe) 'package-manager]
       [else 'unsupported])]
    [(macos)
     (case installer
       [(zip) 'portable]
       [(dmg pkg) 'package-manager]
       [else 'unsupported])]
    [(linux)
     (case installer
       [(zip appimage) 'portable]
       [(deb rpm) 'package-manager]
       [else 'unsupported])]
    [else 'unsupported]))

(define (run-verifier! who executable . arguments)
  (unless executable
    (raise-arguments-error who "required platform verifier was not found"))
  (unless (apply system* executable arguments)
    (raise-arguments-error who
                           "platform signature verification failed"
                           "payload" (last arguments))))

(define (verify-platform-payload! platform payload)
  (case platform
    [(windows)
     (define executable (build-path payload "RivetHost.exe"))
     (unless (file-exists? executable)
       (raise-arguments-error 'verify-platform-payload!
                              "portable Windows payload has no RivetHost.exe"
                              "payload" payload))
     (define powershell
       (or (find-executable-path "pwsh.exe")
           (find-executable-path "powershell.exe")))
     (run-verifier!
      'verify-platform-payload! powershell
      "-NoLogo" "-NoProfile" "-NonInteractive" "-Command"
      (string-append
       "$signature = Get-AuthenticodeSignature -LiteralPath $args[0]; "
       "if ($signature.Status -ne 'Valid') { "
       "Write-Error ('RivetHost.exe Authenticode status: ' + $signature.Status); "
       "exit 1 }")
      (path->string executable))]
    [(macos)
     (run-verifier! 'verify-platform-payload!
                    (find-executable-path "codesign")
                    "--verify" "--deep" "--strict" (path->string payload))]
    [(linux)
     ;; Linux portable updates are authorized by the signed manifest and its
     ;; exact size/SHA-256. deb/rpm are never routed here.
     (void)]
    [else
     (raise-arguments-error 'verify-platform-payload!
                            "unsupported update platform"
                            "platform" platform)]))

(define (path-present? path)
  (or (file-exists? path)
      (directory-exists? path)
      (link-exists? path)))

(define (remove-path! path)
  (cond
    [(link-exists? path) (delete-file path)]
    [(directory-exists? path) (delete-directory/files path)]
    [(file-exists? path) (delete-file path)]))

(define (sibling-path target suffix)
  (string->path (string-append (path->string target) suffix)))

(define (normalize-target who path)
  (unless (complete-path? path)
    (raise-argument-error who "complete-path?" path))
  (simplify-path path #f))

(define (stage-zip! downloaded staging-root)
  (make-directory staging-root)
  (unzip downloaded
         (make-filesystem-entry-reader #:dest staging-root #:exists 'error)
         #:preserve-attributes? #t)
  (define entries (directory-list staging-root #:build? #t))
  (unless (= (length entries) 1)
    (raise-arguments-error 'prepare-platform-installation
                           "portable archive must contain exactly one root entry"
                           "entry-count" (length entries)))
  (car entries))

(define (stage-appimage! downloaded staging-root)
  (make-directory staging-root)
  (define staged (build-path staging-root "application.AppImage"))
  (copy-file downloaded staged)
  (file-or-directory-permissions staged #o755)
  staged)

(define (prepare-platform-installation
         candidate downloaded-path
         #:target target-path
         #:restart restart
         #:health-check health-check
         #:verify-staged [verify-staged #f]
         #:backup-path [configured-backup-path #f])
  (unless (update-candidate? candidate)
    (raise-argument-error 'prepare-platform-installation
                          "update-candidate?" candidate))
  (unless (procedure? restart)
    (raise-argument-error 'prepare-platform-installation "procedure?" restart))
  (unless (procedure? health-check)
    (raise-argument-error 'prepare-platform-installation
                          "procedure?" health-check))
  (define artifact (update-candidate-artifact candidate))
  (define platform (update-artifact-platform artifact))
  (define installer (update-artifact-installer artifact))
  (define running-platform (current-update-platform))
  (unless (eq? platform running-platform)
    (raise-arguments-error 'prepare-platform-installation
                           "candidate targets a different operating system"
                           "candidate-platform" platform
                           "running-platform" running-platform))
  (case (platform-installer-policy platform installer)
    [(package-manager)
     (raise-arguments-error
      'prepare-platform-installation
      "installer is owned by the operating-system package manager"
      "platform" platform
      "installer" installer
      "policy" "invoke the native installer/package manager with elevation outside the portable adapter")]
    [(unsupported)
     (raise-arguments-error 'prepare-platform-installation
                            "unsupported installer for platform"
                            "platform" platform
                            "installer" installer)])

  (define downloaded (normalize-target 'prepare-platform-installation
                                       downloaded-path))
  (define target (normalize-target 'prepare-platform-installation target-path))
  (define backup
    (normalize-target
     'prepare-platform-installation
     (or configured-backup-path (sibling-path target ".rivet-backup"))))
  (define staging-root (sibling-path target ".rivet-staging"))
  (define no-previous-marker (sibling-path backup ".empty"))
  (when (or (equal? downloaded target)
            (equal? downloaded backup)
            (equal? target backup))
    (raise-arguments-error 'prepare-platform-installation
                           "download, target, and backup paths must be distinct"))
  (when (or (link-exists? target) (link-exists? backup))
    (raise-arguments-error 'prepare-platform-installation
                           "target and backup must not be symbolic links"
                           "target" target
                           "backup" backup))

  (define verifier
    (or verify-staged
        (lambda (payload) (verify-platform-payload! platform payload))))

  (define (install downloaded-input)
    (unless (equal? (normalize-target 'platform-update-install downloaded-input)
                    downloaded)
      (raise-arguments-error 'platform-update-install
                             "install plan received an unexpected artifact path"
                             "expected" downloaded
                             "actual" downloaded-input))
    (unless (file-exists? downloaded)
      (raise-arguments-error 'platform-update-install
                             "verified update artifact does not exist"
                             "artifact" downloaded))
    (when (or (path-present? backup) (path-present? no-previous-marker))
      (raise-arguments-error
       'platform-update-install
       "an unfinished installation must be recovered before starting another"
       "backup" backup))
    (when (path-present? staging-root) (remove-path! staging-root))
    (make-parent-directory* target)
    (define staged-payload
      (case installer
        [(zip) (stage-zip! downloaded staging-root)]
        [(appimage) (stage-appimage! downloaded staging-root)]))
    (verifier staged-payload)
    (if (path-present? target)
        (rename-file-or-directory target backup)
        (call-with-output-file no-previous-marker
          #:exists 'error
          (lambda (out) (display "no previous installation\n" out))))
    (rename-file-or-directory staged-payload target)
    (when (directory-exists? staging-root)
      (delete-directory/files staging-root)))

  (define (rollback)
    ;; Idempotent in every interruption window. Neither marker existing means
    ;; installation had not yet moved or created the target.
    (cond
      [(path-present? backup)
       (when (path-present? target) (remove-path! target))
       (rename-file-or-directory backup target)]
      [(file-exists? no-previous-marker)
       (when (path-present? target) (remove-path! target))
       (delete-file no-previous-marker)])
    (when (path-present? staging-root) (remove-path! staging-root)))

  (define (commit)
    ;; Cleanup is deliberately idempotent: recovery may repeat it after the
    ;; filesystem side effect and before the committed phase is durable.
    (when (path-present? backup) (remove-path! backup))
    (when (file-exists? no-previous-marker) (delete-file no-previous-marker))
    (when (path-present? staging-root) (remove-path! staging-root)))

  (platform-installation
   (make-install-plan candidate downloaded
                      #:backup-path backup
                      #:install install
                      #:restart restart
                      #:rollback rollback)
   health-check
   commit))

(define (execute-platform-installation! installation
                                        #:journal-path [journal-path #f])
  (unless (platform-installation? installation)
    (raise-argument-error 'execute-platform-installation!
                          "platform-installation?" installation))
  (execute-install-plan!
   (platform-installation-plan installation)
   #:health-check (platform-installation-health-check installation)
   #:commit (platform-installation-commit installation)
   #:journal-path journal-path))

(define (recover-platform-installation! installation journal-path)
  (unless (platform-installation? installation)
    (raise-argument-error 'recover-platform-installation!
                          "platform-installation?" installation))
  (recover-install-plan!
   (platform-installation-plan installation)
   journal-path
   #:commit (platform-installation-commit installation)))

(module+ test-support
  (provide detect-install-kind))
