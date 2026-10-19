#lang racket/base

;; Guards the first-party Linux AppImage handoff (issue #290). The shell
;; script the helper generates is the crash-safe counterpart of the Windows
;; MsiHandoff install.cmd; these assertions pin the lifecycle steps that
;; every GTK host depends on, on hosts that cannot run the Linux suite.

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "../..")
(define source
  (file->string
   (build-path repository-root "platform" "linux" "update"
               "update_handoff.cpp")))
(define header
  (file->string
   (build-path repository-root "platform" "linux" "update"
               "update_handoff.hpp")))
(define linux-sources
  (file->string
   (build-path repository-root "platform" "linux"
               "rivet_linux_sources.cmake")))

;; Detached lifecycle: the helper waits a bounded time for the launching
;; process, then drives the transaction out of process.
(for ([required (in-list '("kill -0 \\\"$RIVET_OLD_PID\\\""
                           "process-exit-timeout"
                           "sleep 1"
                           "transaction-busy"
                           "rivet_lock_acquired"
                           "rivet_preflight"
                           ".rivet-backup"
                           ".rivet-backup.empty"
                           ".rivet-staging"
                           ".rivet-handoff-journal"
                           "no previous installation"
                           "sha256sum"
                           "candidate-mismatch"
                           "replace-backup-failed"
                           "replace-install-failed"
                           "replacement-unhealthy"
                           "replacement-unhealthy-rollback-forbidden"
                           "failure.txt"
                           "mv -f \\\"$RIVET_TARGET\\\" \\\"$RIVET_BACKUP\\\""
                           "mv -f \\\"$RIVET_STAGING/application.AppImage\\\""))])
  (check-true (string-contains? source required)
              (format "Linux handoff lost required lifecycle step: ~a"
                      required)))

;; Journal phases stay aligned with rivet/distribution's schema-1 install
;; journal so recovery tooling can consume an interrupted handoff.
(for ([phase (in-list '("prepared" "installing" "installed" "restarting"
                        "restarted" "checking" "healthy" "committing"
                        "committed" "rollback-started" "rolled-back"
                        "rollback-failed"))])
  (check-true (string-contains? source (format "\"~a\"" phase))
              (format "Linux handoff journal lost phase: ~a" phase)))

;; Detached execution and the lease-release ordering the docs promise.
(for ([required (in-list '("setsid"
                           "execv"
                           "/bin/sh"
                           "release_lease"
                           "XDG_STATE_HOME"))])
  (check-true (string-contains? source required)
              (format "Linux handoff lost required execution step: ~a"
                      required)))

;; The public lifecycle mirrors MsiHandoff: launch, consume the failure
;; marker, clean stale attempts.
(for ([required (in-list '("ConsumeFailure"
                           "CleanupStaleAttempts"
                           "LaunchReplacement"
                           "AppImageHandoffOptions"
                           "rollback_allowed"
                           "settle_seconds"))])
  (check-true (string-contains? header required)
              (format "Linux handoff header lost required API: ~a" required)))

(check-true (string-contains? linux-sources "update/update_handoff.cpp")
            "the released Linux platform library must compile the handoff")
