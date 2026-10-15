#lang racket/base

(require racket/list
         rackunit)

;; This is an intentional compatibility boundary, not a documentation index.
;; Every phase-0 export is listed so that adding an accidental helper is caught
;; just as reliably as removing or renaming an existing binding.
(define expected-public-api
  '((rivet
     (app-build app-display-name app-identifier app-info app-info-build
      app-info-display-name app-info-identifier app-info-name
      app-info-release-channel app-info-version app-info? app-name
      app-release-channel app-version backend-schema
      backend-schema->app-schema current-app-info current-backend-app-schema
      current-resource-root current-rivet-diagnostic-sink decode-value
      define-enum define-event define-record define-rpc define-state
      emit-event! encode-value enum-case enum-schema event-schema frame
      frame-id frame-payload frame-type frame? max-frame-payload-size
      max-value-depth max-value-nodes message:cancel message:error
      message:event message:hello message:request message:response
      message:shutdown protocol-version read-frame record-ref record-schema
      resource-path resource-root rpc-schema serve serve-fds state-ref
      state-schema state-set! state? struct:app-info struct:frame write-frame))
    (rivet/app-info
     (app-build app-display-name app-identifier app-info app-info-build
      app-info-display-name app-info-identifier app-info-name
      app-info-release-channel app-info-version app-info? app-name
      app-release-channel app-version current-app-info struct:app-info))
    (rivet/backend
     (backend-schema current-rivet-diagnostic-sink define-enum define-event
      define-record define-rpc define-state emit-event! enum-case enum-schema
      event-schema record-ref record-schema rpc-schema serve serve-fds
      state-ref state-schema state-set! state?))
    (rivet/keel
     (backend-schema->app-schema current-backend-app-schema))
    (rivet/protocol
     (decode-value encode-value frame frame-id frame-payload frame-type frame?
      max-frame-payload-size max-value-depth max-value-nodes message:cancel
      message:error message:event message:hello message:request
      message:response message:shutdown protocol-version read-frame
      struct:frame write-frame))
    (rivet/resources
     (current-resource-root resource-path resource-root))
    (rivet/system
     (acquire-single-instance! autostart-enabled? call-with-crash-reporting
      current-rivet-crash-reporter current-rivet-log-sink
      current-system-adapter install-crash-hook! make-settings-store
      register-activation-handler! rivet-log secure-store-ref
      secure-store-remove! secure-store-set! set-autostart!
      set-tray-menu! settings-ref settings-remove! settings-set!
      settings-snapshot settings-store? show-system-notification!
      struct:system-adapter
      system-adapter system-adapter-acquire-single-instance
      system-adapter-autostart-enabled system-adapter-capabilities
      system-adapter-install-crash-hook system-adapter-name
      system-adapter-register-activation-handler
      system-adapter-secure-store-ref system-adapter-secure-store-remove
      system-adapter-secure-store-set system-adapter-set-autostart
      system-adapter-set-tray-menu system-adapter-show-notification
      system-adapter? system-capabilities))
    (rivet/distribution
     (architecture-symbol base64-string->bytes bytes->base64-string bytes->ed25519-public-key
      channel-accepts-version? current-install-kind current-update-platform
      current-update-architecture download-update ed25519-sign ed25519-verify
      execute-install-plan!
      execute-platform-installation! fetch-update-manifest install-plan
      install-plan-backup-path install-plan-candidate
      install-plan-downloaded-path install-plan-install install-plan-restart
      install-plan-rollback install-plan? installer-extension make-install-plan
      manifest->payload-bytes manifest-schema-version payload-bytes->manifest
      make-updater platform-installation? platform-installer-policy
      platform-symbol prepare-platform-installation read-ed25519-private-key
      read-ed25519-public-key read-signed-manifest recover-install-plan!
      recover-platform-installation! select-update sha256-bytes sha256-file
      sha256-file/hex struct:install-plan
      struct:update-artifact struct:update-candidate struct:update-manifest
      struct:updater-config update-artifact update-artifact-architecture
      update-artifact-arguments update-artifact-installer
      update-artifact-platform update-artifact-sha256 update-artifact-size
      update-artifact-url update-artifact? update-candidate
      update-candidate-artifact update-candidate-manifest update-candidate?
      update-manifest update-manifest-application-id update-manifest-artifacts
      update-manifest-build update-manifest-channel
      update-manifest-minimum-version update-manifest-previous-version
      update-manifest-published-at update-manifest-rollback-allowed?
      update-manifest-rollout update-manifest-version update-manifest?
      updater-cancel! updater-check! updater-download! updater-state
      updater-config updater-config-application-id
      updater-config-architecture updater-config-channel
      updater-config-current-version updater-config-expected-key-id
      updater-config-maximum-download-bytes updater-config-platform
      updater-config-public-key updater-config-rollout-bucket updater-config?
      updater-wait updater? rfc3339-now
      valid-channel? verify-platform-payload! verify-signed-manifest
      verify-update-artifact! version-compare version<=? version<? version=?
      version>=? version>? version? write-signed-manifest))
    (rivet/distribution/identity
     (architecture-symbol installer-extension platform-symbol rfc3339-now))
    (rivet/testing
     (ephemeral-http-listener fake-request fake-request-body
      fake-request-headers fake-request-method fake-request-path fake-request?
      serve-http! struct:fake-request))))

(define (phase-zero-export-names exports)
  (for*/list ([phase-entry (in-list exports)]
              #:when (equal? (car phase-entry) 0)
              [export-entry (in-list (cdr phase-entry))])
    (car export-entry)))

(define (public-export-names module-path)
  (dynamic-require module-path #f)
  (define-values (variable-exports syntax-exports)
    (module->exports module-path))
  (sort (remove-duplicates
         (append (phase-zero-export-names variable-exports)
                 (phase-zero-export-names syntax-exports)))
        symbol<?))

(for ([entry (in-list expected-public-api)])
  (define module-path (car entry))
  (define expected (sort (cadr entry) symbol<?))
  (test-case (format "public exports: ~a" module-path)
    (check-equal? (public-export-names module-path) expected)))
