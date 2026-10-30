#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/set
         racket/string)

(define-runtime-path repository-root-reference "../..")
(define repository-root (simplify-path repository-root-reference #t))

(define (markdown-file? path)
  (and (file-exists? path)
       (regexp-match? #rx#"[.]md$" (path->bytes path))))

(define markdown-files
  (append
   (filter markdown-file? (directory-list repository-root #:build? #t))
   (find-files markdown-file? (build-path repository-root "docs"))
   (let ([examples (build-path repository-root "examples")])
     (if (directory-exists? examples)
         (find-files markdown-file? examples)
         '()))))

(define (fence-line? line)
  (regexp-match? #px"^[ \t]*(```|~~~)" line))

(define (prose-without-fences text)
  ;; Code examples frequently contain callback syntax that resembles a
  ;; Markdown link. Only prose links are repository navigation contracts.
  (let loop ([lines (string-split text "\n" #:trim? #f)]
             [inside-fence? #f]
             [visible '()])
    (cond
      [(null? lines) (string-join (reverse visible) "\n")]
      [(fence-line? (car lines))
       (loop (cdr lines) (not inside-fence?) visible)]
      [inside-fence? (loop (cdr lines) inside-fence? visible)]
      [else (loop (cdr lines) inside-fence? (cons (car lines) visible))])))

(define markdown-link-rx #px"\\[[^]\r\n]+\\]\\(([^ \t\r\n)]+)")

(define (link-destinations path)
  (regexp-match*
   markdown-link-rx
   (prose-without-fences (file->string path))
   #:match-select cadr))

(define (external-or-anchor? destination)
  (or (string-prefix? destination "#")
      (regexp-match? #px"^[A-Za-z][A-Za-z0-9+.-]*:" destination)))

(define (strip-angle-brackets destination)
  (if (and (string-prefix? destination "<")
           (string-suffix? destination ">"))
      (substring destination 1 (sub1 (string-length destination)))
      destination))

(for* ([source (in-list markdown-files)]
       [raw-destination (in-list (link-destinations source))])
  (define destination (strip-angle-brackets raw-destination))
  (unless (external-or-anchor? destination)
    (define relative (car (string-split destination "#")))
    (define target (build-path (path-only source) relative))
    (check-true
     (or (file-exists? target) (directory-exists? target))
     (format "broken local Markdown link in ~a: ~a"
             (find-relative-path repository-root source)
             destination))))

;; Keep one canonical documentation map. New top-level guides must be linked
;; there instead of becoming invisible pages that duplicate an existing owner.
(define docs-root (build-path repository-root "docs"))
(define docs-map (build-path docs-root "README.md"))
(define mapped-guides
  (for/list ([destination (in-list (link-destinations docs-map))])
    (car (string-split destination "#"))))
(for ([guide (in-list (filter markdown-file?
                              (directory-list docs-root #:build? #t)))]
      #:unless (equal? guide docs-map))
  (define name (path->string (file-name-from-path guide)))
  (check-not-false
   (member name mapped-guides)
   (format "docs/README.md must link top-level guide ~a" name)))

(struct checkbox (indent checked? line) #:transparent)

(define (read-checkboxes path)
  (for/list ([line (in-list (file->lines path))]
             #:do [(define match
                     (regexp-match #px"^( *)- \\[([ xX])\\] " line))]
             #:when match)
    (checkbox (string-length (list-ref match 1))
              (not (string=? (list-ref match 2) " "))
              line)))

(define english-checkboxes
  (read-checkboxes (build-path repository-root "README.md")))
(define chinese-checkboxes
  (read-checkboxes (build-path repository-root "README.zh-CN.md")))

(check-equal?
 (map (lambda (item) (cons (checkbox-indent item) (checkbox-checked? item)))
      english-checkboxes)
 (map (lambda (item) (cons (checkbox-indent item) (checkbox-checked? item)))
      chinese-checkboxes)
 "English and Chinese README roadmap checkboxes must stay in sync")

(define (check-completed-parent-boxes path)
  (define boxes (read-checkboxes path))
  (for ([parent (in-list boxes)]
        [index (in-naturals)]
        #:when (zero? (checkbox-indent parent)))
    (define children
      (takef (drop boxes (add1 index))
             (lambda (candidate) (positive? (checkbox-indent candidate)))))
    (when (and (pair? children)
               (andmap checkbox-checked? children))
      (check-true
       (checkbox-checked? parent)
       (format "completed roadmap children require a checked parent in ~a: ~a"
               (find-relative-path repository-root path)
               (checkbox-line parent))))))

(check-completed-parent-boxes (build-path repository-root "README.md"))
(check-completed-parent-boxes (build-path repository-root "README.zh-CN.md"))

(define (check-file-contains path expected [message #f])
  (check-true
   (string-contains? (file->string path) expected)
   (or message
       (format "~a must contain ~s"
               (find-relative-path repository-root path)
               expected))))

;; The three production desktop targets must remain equally visible in the
;; landing page and both README variants. This catches the class of drift where
;; Linux support exists in code but disappears from product-facing copy.
(define readme (build-path repository-root "README.md"))
(define readme-zh (build-path repository-root "README.zh-CN.md"))
(define landing-page (build-path repository-root "docs" "index.html"))
(for ([path (in-list (list readme readme-zh landing-page))])
  (for ([platform (in-list '("Windows" "macOS" "Linux"))])
    (check-file-contains path platform)))
(check-file-contains readme "![Linux]")
(check-file-contains readme-zh "![Linux]")
(check-file-contains landing-page "WinUI 3 / SwiftUI / GTK4")

;; The CI guide must pin the package version this checkout declares, so a
;; release that forgets the guide turns this suite red instead of shipping
;; instructions for a stale tag.
(define release-version
  (second (regexp-match #px"\\(define release-version \"([0-9.]+)\"\\)"
                        (file->string (build-path repository-root "info.rkt")))))
(define pinned-tag (format "v~a" release-version))
(define pinned-package-url
  (format "https://github.com/turlamai/rivet.git#v~a" release-version))

(define package-info (file->string (build-path repository-root "info.rkt")))
(for ([generated-path (in-list '("platform/macos/.build" ".rivet" "dist"))])
  (check-true
   (string-contains? package-info generated-path)
   (format "info.rkt source-omit-files must exclude generated path ~a"
           generated-path)))

(define ci-guide (build-path repository-root "docs" "ci.md"))
(define ci-guide-zh (build-path repository-root "docs" "ci.zh-CN.md"))
(for ([expected (in-list '("windows-latest"
                           "macos-latest"
                           "macos-15"
                           "ubuntu-24.04"
                           "setup-embed-racket"
                           "raco rivet build"))])
  (check-file-contains ci-guide expected))
(check-file-contains ci-guide-zh "raco rivet build")
(for ([guide (in-list (list ci-guide ci-guide-zh))])
  (check-file-contains
   guide
   pinned-package-url
   (format "docs/ci*.md must pin the current release tag ~a; bump the guide with every release"
           pinned-tag))
  (check-file-contains
   guide
   (format "setup-embed-racket@v~a" release-version)
   (format "docs/ci*.md must pin the embeddable-runtime action to ~a" pinned-tag))
  (define text (file->string guide))
  (check-true
   (regexp-match?
    (pregexp (format "(?s:linux-host:.*setup-embed-racket@~a.*raco pkg install.*rivet[.]git#~a)"
                     (regexp-quote pinned-tag)
                     (regexp-quote pinned-tag)))
    text)
   (format "~a must install the pinned package after the embeddable runtime"
           (find-relative-path repository-root guide))))

(define embed-action
  (build-path repository-root ".github" "actions" "setup-embed-racket" "action.yml"))
;; Packaged copies of the repository legitimately lack dot-directories (the
;; package build farm installs one), so the CI-wiring checks only run where
;; the checkout actually contains them.
(when (file-exists? embed-action)
  (for ([expected (in-list '("actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
                             "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
                             "sha256sum --check"
                             "RIVET_RACKET_INCLUDE"
                             "RIVET_RACKET_LIBRARY"
                             "RIVET_RACKET_BOOT_DIR"))])
    (check-file-contains embed-action expected)))

(define configuration-guide
  (build-path repository-root "docs" "configuration.md"))
(check-file-contains configuration-guide
                     "(resources . (\"shared/i18n\" \"shared/emoji.json\"))")
(check-file-contains configuration-guide "stage/res")
(check-file-contains configuration-guide "stage/app")

(define runtime-limits-guide
  (build-path repository-root "docs" "runtime-limits.md"))
(check-file-contains runtime-limits-guide "Windows, macOS, and Linux")

(define protocol-guide (build-path repository-root "docs" "protocol.md"))
(check-file-contains protocol-guide "The RVT1 v1 value-tag set is closed")
(for ([deferred (in-list '("Float64" "Map" "structured Error"))])
  (check-file-contains protocol-guide deferred))
(define large-payloads-guide
  (build-path repository-root "docs" "large-payloads.md"))
(check-file-contains large-payloads-guide "fraction-bps : Int64")
(check-false
 (regexp-match? #px"fraction[ ]*:[ ]*Float64" (file->string large-payloads-guide))
 "large-payloads guide must not present unsupported Float64 as RVT1 v1 schema")

(define system-services-guide
  (build-path repository-root "docs" "system-services.md"))
(for ([expected (in-list '("TrayController"
                           "SetWindowSubclass"
                           "TaskbarCreated"
                           "SetForegroundWindow"
                           "TrackPopupMenu"))])
  (check-file-contains system-services-guide expected))

;; --- Scribble coverage: every public export documented, no phantom docs ---
;;
;; Documentation rots silently when a new export lands without a manual
;; entry or when a renamed binding leaves stale entries behind. Both
;; directions fail this suite. A name counts as documented when it is
;; mentioned in the scribble source or is synthesized by a @defstruct*
;; form, whose rendered output covers the constructor, predicate,
;; structure-type binding, and every field accessor.

(define scribble-source
  (build-path repository-root "rivet" "scribblings" "rivet.scrbl"))
(define scribble-text (file->string scribble-source))

;; rivet/testing is internal test support and deliberately stays out of the
;; user manual.
(define documented-modules
  '(rivet rivet/app-info rivet/backend rivet/chart rivet/keel rivet/protocol
    rivet/resources rivet/system rivet/distribution))

(define ident-chars "A-Za-z0-9_!?<>=/\\+\\-*:.#")
(define (mentioned? name text)
  (regexp-match?
   (pregexp (format "(?<![~a])~a(?![~a])"
                    ident-chars (regexp-quote name) ident-chars))
   text))

(define defstruct-entries
  (regexp-match*
   #px"@defstruct\\*\\[\\s*([A-Za-z0-9!?<>=/\\+\\-*:.#-]+)\\s*\\(\\s*((?:\\[[^]]+\\]\\s*)+)"
   scribble-text
   #:match-select (lambda (match) (list (list-ref match 1) (list-ref match 2)))))

(define (defstruct-synthesized-names entry)
  (define name (car entry))
  (define field-ids
    (map (lambda (field)
           (first (string-split
                   (string-trim (regexp-replace #px"^\\[|\\]$" field "")) " ")))
         (regexp-match* #px"\\[[^]]+\\]" (cadr entry))))
  (cons name
        (cons (string-append name "?")
              (cons (string-append "struct:" name)
                    (for/list ([field (in-list field-ids)])
                      (string-append name "-" field))))))

(define synthesized-names (append* (map defstruct-synthesized-names defstruct-entries)))

(define (module-export-names module-path)
  (dynamic-require module-path #f)
  (define-values (variables syntax-exports)
    (module->exports module-path))
  (define (phase-zero-names exports)
    (for*/list ([phase-entry (in-list exports)]
                #:when (equal? (car phase-entry) 0)
                [export-entry (in-list (cdr phase-entry))])
      (car export-entry)))
  (remove-duplicates
   (append (phase-zero-names variables) (phase-zero-names syntax-exports))))

(define exported-names
  (remove-duplicates
   (append* (map module-export-names documented-modules))))

(for ([name (in-list exported-names)])
  (define as-string (symbol->string name))
  ;; member returns a (truthy) tail list, not #t — assert truthiness, not
  ;; boolean identity.
  (check-not-false
   (or (member as-string synthesized-names) (mentioned? as-string scribble-text))
   (format "public export is not documented in rivet.scrbl: ~a" name)))

;; Phantom documentation: a documented identifier must still be exported.
(define documented-identifier-rxs
  (list #px"@defproc\\[\\(\\s*([A-Za-z0-9!?<>=/\\+\\-*:.#-]+)"
        #px"@defthing\\[\\s*([A-Za-z0-9!?<>=/\\+\\-*:.#-]+)"
        #px"@defform\\[\\(\\s*([A-Za-z0-9!?<>=/\\+\\-*:.#-]+)"
        #px"@defparam\\[\\s*([A-Za-z0-9!?<>=/\\+\\-*:.#-]+)"))
(define documented-identifiers
  (remove-duplicates
   (append (apply append
                  (for/list ([rx (in-list documented-identifier-rxs)])
                    (regexp-match* rx scribble-text #:match-select cadr)))
           synthesized-names)))
(define exported-name-strings (list->set (map symbol->string exported-names)))
(for ([identifier (in-list documented-identifiers)])
  (check-true
   (set-member? exported-name-strings identifier)
   (format "rivet.scrbl documents ~a, which is not a public export; the manual entry is stale"
           identifier)))

;; --- Update API keyword contract doc (issue #255) ---
;;
;; docs/release-and-updates.md lists the keyword contracts of the update API
;; as the stable surface hosts call into. This guard parses those bullets
;; and compares them against the installed procedures' own
;; procedure-keywords contract, so the documented surface cannot drift from
;; the code in either direction.

(define contract-doc-text
  (file->string
   (build-path repository-root "docs" "release-and-updates.md")))

(define contract-doc-line-rx
  #px"^\\s*-\\s+`([a-z0-9-]+)` accepts((?: `#:[a-z0-9-]+`)*)[.]\\s*$")

(define documented-contracts
  (for/hash ([line (in-list (string-split contract-doc-text "\n"))]
             #:when (regexp-match? contract-doc-line-rx line))
    (define match (regexp-match contract-doc-line-rx line))
    (define name (string->symbol (list-ref match 1)))
    (define keywords
      (map (lambda (token) (string->symbol (substring token 2)))
           (regexp-match* #px"`(#[a-z0-9:-]+)`" (list-ref match 2)
                          #:match-select cadr)))
    (values name keywords)))

(define contract-procedures
  '(fetch-update-manifest select-update download-update fetch-sibling-asset))

(for ([name (in-list contract-procedures)])
  (define proc
    (dynamic-require 'rivet/distribution name))
  (define-values (_required allowed-keywords) (procedure-keywords proc))
  ;; procedure-keywords returns keyword objects; the documentation bullets
  ;; compare as symbols for readability.
  (define allowed
    (map (lambda (kw) (string->symbol (keyword->string kw))) allowed-keywords))
  (check-true
   (hash-has-key? documented-contracts name)
   (format "docs/release-and-updates.md has no keyword-contract bullet for ~a" name))
  (when (hash-has-key? documented-contracts name)
    ;; Keyword order is not part of the contract; compare as sets.
    (check-equal?
     (sort (hash-ref documented-contracts name) symbol<?)
     (sort allowed symbol<?)
     (format "docs/release-and-updates.md keyword contract for ~a drifted from the installed rivet"
             name))))

(for ([name (in-hash-keys documented-contracts)])
  ;; memq returns a truthy tail, not #t — assert truthiness.
  (check-not-false
   (memq name contract-procedures)
   (format "docs/release-and-updates.md documents a keyword contract for ~a, which the release gate does not scan"
           name)))
