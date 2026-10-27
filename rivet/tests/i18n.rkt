#lang racket/base

(require json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/system
         rackunit
         "../../rivet-cli/i18n.rkt"
         "../../rivet-cli/project.rkt"
         "../../rivet-cli/scaffold.rkt")

(define-runtime-path repository-root "../..")

(define temp-root (make-temporary-file "rivet-i18n-~a" 'directory))
(dynamic-wind
  void
  (lambda ()
    (define project-root (create-project! "localized" temp-root))
    (define (write-table! language content)
      (make-directory* (build-path project-root "shared" "i18n"))
      (call-with-output-file
       (build-path project-root "shared" "i18n"
                   (string-append language ".json"))
       #:exists 'truncate/replace
       (lambda (out) (display content out))))

    ;; Missing tables are a hard error with a file-naming message.
    (check-exn #rx"missing zh table"
               (lambda () (generate-i18n! (load-project project-root))))
    (write-table! "zh" "{\"app.title\": \"示例\"}")
    (check-exn #rx"missing en table"
               (lambda () (generate-i18n! (load-project project-root))))

    ;; The healthy path: flat zh/en maps with identical key sets regenerate
    ;; every embedded table, escapes intact.
    (write-table!
     "en"
     "{\"app.title\": \"Demo\", \"app.quit\": \"Quit demo\", \"weird\": \"quote\\\" back\\\\ tick\"}")
    (write-table!
     "zh"
     "{\"app.title\": \"示例\", \"app.quit\": \"退出\", \"weird\": \"引号\\\" 反斜杠\\\\\"}")
    (define project (load-project project-root))
    (define-values (keys files)
      (apply values (generate-i18n! project)))
    (check-equal? keys 3)
    (check-equal? files 3)

    (define cpp-table
      (file->string (build-path project-root "windows" "GeneratedI18n.hpp")))
    (define linux-table
      (file->string (build-path project-root "linux" "GeneratedI18n.hpp")))
    (define swift-table
      (file->string
       (build-path project-root "macos-host" "Sources" "RivetHost"
                   "GeneratedI18n.swift")))
    (check-true (string-contains? cpp-table "kI18nTable"))
    (check-true (string-contains? cpp-table "\"app.title\""))
    (check-true (string-contains? cpp-table "\"\\347\\244\\272\\344\\276\\213")
                "non-ASCII content escapes into UTF-8 octal bytes")
    (check-true (string-contains? cpp-table "quote\\\" back\\\\ tick"))
    (check-equal? cpp-table linux-table)
    (check-true (string-contains? swift-table "enum GeneratedI18n"))
    (check-true (string-contains? swift-table "\"app.quit\""))
    (check-true (string-contains? swift-table "\"退出\""))

    ;; The generated C++ table is real C++: compile it with the shipped
    ;; loader and check tr()'s lookup order (active → other → key).
    (define generated-header
      (build-path project-root "windows" "GeneratedI18n.hpp"))
    (define loader-header
      (build-path repository-root "platform" "windows" "host" "i18n.hpp"))
    (define probe-source
      (build-path temp-root "tr-probe.cpp"))
    (call-with-output-file probe-source
      (lambda (out)
        (displayln #<<CPP
#include "i18n.hpp"
#include <cassert>
#include <string>

int main() {
  using namespace rivet_app::i18n;
  // active language wins
  assert(std::string(tr("zh", "app.title")) == "\xE7\xA4\xBA\xE4\xBE\x8B");
  assert(std::string(tr("en", "app.title")) == "Demo");
  // active language missing falls back to the other language
  assert(std::string(tr("zh", "app.quit")) == "\xE9\x80\x80\xE5\x87\xBA");
  // unknown keys return the key itself
  assert(std::string(tr("zh", "nope")) == "nope");
  return 0;
}
CPP
        out))
      #:exists 'truncate)
    (define compiler
      (or (find-executable-path "c++") (find-executable-path "g++")
          (find-executable-path "clang++")))
    (when compiler
      (define compile-exit
        (parameterize ([current-output-port (open-output-nowhere)]
                       [current-error-port (open-output-nowhere)])
          (system* compiler "-std=c++20"
                   (format "-I~a" (path-only generated-header))
                   (format "-I~a" (path-only loader-header))
                   (path->string probe-source)
                   "-o" (path->string (build-path temp-root "tr-probe")))))
      (check-true (and compile-exit #t) "tr() probe must compile")
      (when compile-exit
        (check-equal?
         (parameterize ([current-output-port (open-output-nowhere)]
                        [current-error-port (open-output-nowhere)])
           (system* (build-path temp-root "tr-probe")))
         #t)))

    ;; Freshness gate: regenerate once, then tamper — the release-gate check
    ;; must see stale and missing files until the writer repairs them.
    (check-false (hash? (check-generated-i18n project))
                 "a fresh tree reports no findings")
    (define linux-table-path
      (build-path project-root "linux" "GeneratedI18n.hpp"))
    (call-with-output-file generated-header
      #:exists 'truncate
      (lambda (out) (display "// hand-edited\n" out)))
    (define tampered (check-generated-i18n project))
    (check-equal? (hash-ref tampered 'stale) (list generated-header))
    (delete-file linux-table-path)
    (define tampered-more (check-generated-i18n project))
    (check-equal? (length (hash-ref tampered-more 'missing)) 1)
    (void (generate-i18n! project))
    (check-false (hash? (check-generated-i18n project)))

    ;; Removed platforms stay removed: deleting a host directory and
    ;; regenerating must not resurrect it, and the freshness gate must
    ;; stop demanding its table (single-platform products).
    (delete-directory/files (build-path project-root "macos-host"))
    (define-values (keys-after-removal tables-after-removal)
      (apply values (generate-i18n! project)))
    (check-equal? keys-after-removal 3)
    (check-equal? tables-after-removal 2 "windows + linux tables only")
    (check-false (directory-exists? (build-path project-root "macos-host")))
    (check-false (hash? (check-generated-i18n project))
                 "the freshness gate ignores removed hosts")

    ;; Parity failures for doctor: non-flat structures and drifted key sets
    ;; both surface as messages, and a project without shared/i18n skips.
    (write-table! "en" "{\"nested\": {\"key\": \"value\"}}")
    (write-table! "zh" "{\"nested\": {\"key\": \"值\"}}")
    (define nested-report (check-i18n-parity! project))
    (check-true (and (string? nested-report)
                     (string-contains? nested-report "is not a string")))
    (write-table! "en" "{\"a\": \"1\"}")
    (write-table! "zh" "{\"b\": \"2\"}")
    (define drifted-report (check-i18n-parity! project))
    (check-true (and (string? drifted-report)
                     (string-contains? drifted-report "parity check failed")))
    (delete-directory/files (build-path project-root "shared"))
    (check-false (check-i18n-parity! project)))
  (lambda ()
    (when (directory-exists? temp-root)
      (delete-directory/files temp-root))))
