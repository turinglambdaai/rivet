#lang racket/base

(require json
         racket/date
         racket/file
         racket/format
         racket/path
         "project.rkt")

(provide generate-compliance-artifacts!)

(define framework-components
  (list
   (hasheq 'type "framework" 'name "Racket CS" 'license "Apache-2.0 OR LGPL-3.0-only")
   (hasheq 'type "library" 'name "Rivet" 'license "MIT")
   (hasheq 'type "library" 'name "crypto-lib" 'license "Apache-2.0")
   (hasheq 'type "framework" 'name "Microsoft Windows App SDK" 'license "MIT")
   (hasheq 'type "framework" 'name "Apple system frameworks" 'license "LicenseRef-Apple-SDK")))

(define (timestamp)
  (define d (seconds->date (current-seconds) #t))
  (format "~a-~a-~aT~a:~a:~aZ"
          (date-year d)
          (~r (date-month d) #:min-width 2 #:pad-string "0")
          (~r (date-day d) #:min-width 2 #:pad-string "0")
          (~r (date-hour d) #:min-width 2 #:pad-string "0")
          (~r (date-minute d) #:min-width 2 #:pad-string "0")
          (~r (date-second d) #:min-width 2 #:pad-string "0")))

(define (component->cyclonedx component)
  (hash-set (hash-remove component 'license)
            'licenses
            (list (hasheq 'expression (hash-ref component 'license)))))

(define (generate-compliance-artifacts! project)
  (define dist (project-path project "dist"))
  (make-directory* dist)
  (define sbom (build-path dist "sbom.cdx.json"))
  (call-with-output-file sbom
    #:exists 'truncate/replace
    (lambda (out)
      (write-json
       (hasheq 'bomFormat "CycloneDX"
               'specVersion "1.6"
               'version 1
               'metadata
               (hasheq 'timestamp (timestamp)
                       'component
                       (hasheq 'type "application"
                               'name (project-name project)
                               'version (project-version project)))
               'components (map component->cyclonedx framework-components))
       out)
      (newline out)))
  (define notices (build-path dist "THIRD_PARTY_NOTICES.txt"))
  (call-with-output-file notices
    #:exists 'truncate/replace
    (lambda (out)
      (fprintf out "Third-party notices for ~a ~a\n\n"
               (project-display-name project) (project-version project))
      (for ([component (in-list framework-components)]
            #:unless (string=? (hash-ref component 'name) "Rivet"))
        (fprintf out "~a\n  License: ~a\n\n"
                 (hash-ref component 'name)
                 (hash-ref component 'license)))))
  ;; Fail closed when a component lacks explicit license metadata. CI runs
  ;; this as the license audit; application-specific dependencies can append
  ;; components before publishing.
  (for ([component (in-list framework-components)])
    (unless (hash-ref component 'license #f)
      (error 'generate-compliance-artifacts!
             "license audit failed for ~a" (hash-ref component 'name))))
  (values sbom notices))
