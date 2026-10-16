#lang racket/base

;; Single-source user-visible strings (issue #242). Projects keep one flat
;; `shared/i18n/{zh,en}.json` pair; this module verifies the parity contract
;; (both files are flat string->string maps with identical key sets) and
;; regenerates the per-platform embedded tables the host loaders consume, so
;; a key can never exist in one host's fallback and not another's — the
;; fulcrum win/linux drift that motivated this command.

(require json
         racket/file
         racket/format
         racket/list
         racket/string
         "project.rkt")

(provide load-i18n-table
         check-i18n-parity!
         i18n-outputs
         generate-i18n!
         check-generated-i18n
         cpp-string-view-literal
         swift-string-literal-value)

(define i18n-languages '(zh en))

(define (language-file project language)
  (project-path project "shared" "i18n" (format "~a.json" language)))

;; Reads one language file and enforces the flat string->string shape. The
;; error messages name the file and the offending key so a project with a
;; hand-grown nested structure can find the exact spot to flatten.
(define (read-language-table! project language)
  ;; read-json returns JSON object keys as symbols; normalize them to
  ;; strings because the table's contract — and the generated tables — are
  ;; string-keyed.
  (define path (language-file project language))
  (unless (file-exists? path)
    (error 'i18n "missing ~a table; expected ~a" language path))
  (define table
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (error 'i18n "~a is not valid JSON: ~a" path (exn-message e)))])
      (call-with-input-file path read-json)))
  (unless (hash? table)
    (error 'i18n "~a must be a flat JSON object" path))
  (for/hash ([(key value) (in-hash table)])
    (unless (or (string? key) (symbol? key))
      (error 'i18n "~a key ~a is not a string" path key))
    (unless (string? value)
      (error 'i18n "~a value for ~a is not a string" path key))
    (values (if (symbol? key) (symbol->string key) key) value)))

;; Returns an association list of (key . (zh-value en-value)) sorted by key,
;; raising when the parity contract fails.
(define (load-i18n-table project)
  (define tables
    (for/hasheq ([language (in-list i18n-languages)])
      (values language (read-language-table! project language))))
  (define keys
    (sort (remove-duplicates
           (append* (for/list ([language (in-list i18n-languages)])
                      (hash-keys (hash-ref tables language)))))
          string<?))
  (for* ([language (in-list i18n-languages)]
         [key (in-list keys)])
    (unless (hash-has-key? (hash-ref tables language) key)
      (error 'i18n
             "parity check failed: key ~a exists in another language but not in ~a (~a)"
             key language (language-file project language))))
  (for/list ([key (in-list keys)])
    (cons key
          (for/list ([language (in-list i18n-languages)])
            (hash-ref (hash-ref tables language) key)))))

;; The standalone parity check for doctor/CI use: returns #f when the table
;; is healthy, or a failure message string.
(define (check-i18n-parity! project)
  (define shared-dir (project-path project "shared" "i18n"))
  (if (directory-exists? shared-dir)
      (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
        (void (load-i18n-table project))
        #f)
      #f))

;; Racket strings into C++ string_view literals. Unlike identifiers, string
;; content only needs escaping, and the surrounding quotes are added here.
;; Non-printable characters split the literal (`"\x0a" "rest"`) so a hex
;; escape can never swallow following digits.
(define (hex-2 n)
  ;; Two lowercase hex digits, zero-padded — the common width forms of
  ;; racket/format differ between ~a and ~r, so pad by hand.
  (define digits (number->string n 16))
  (if (< (string-length digits) 2)
      (string-append "0" digits)
      digits))

(define (cpp-string-view-literal text)
  ;; Every byte outside the printable ASCII range becomes a three-digit
  ;; octal escape over the UTF-8 encoding: fixed width, so consecutive
  ;; escapes cannot run into each other (unlike \xNN, whose greedy hex
  ;; digits force string splits and cannot exceed one byte anyway).
  (string-append
   "\""
   (string-append*
    (for/list ([byte (in-list (bytes->list (string->bytes/utf-8 text)))])
      (cond
        [(= byte 10) "\\n"]
        [(= byte 13) "\\r"]
        [(= byte 9) "\\t"]
        [(= byte 34) "\\\""]
        [(= byte 92) "\\\\"]
        [(and (>= byte 32) (<= byte 126))
         (string (integer->char byte))]
        [else
         (format "\\~o" byte)])))
   "\""))

(define (swift-string-literal-value text)
  ;; Swift sources are UTF-8 by default: keep non-ASCII readable, escape
  ;; only quotes, backslashes, and C0 control characters.
  (string-append
   "\""
   (regexp-replace* #px"[\"\\\\]|[\x00-\x1f]"
                    text
                    (lambda (match)
                      (define char (string-ref match 0))
                      (case char
                        [(#\") "\\\""]
                        [(#\\) "\\\\"]
                        [(#\nul) "\\0"]
                        [else
                         (format "\\u{~a}"
                                 (hex-2 (char->integer char)))])))
   "\""))

(define (cpp-i18n-header table)
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n"
   "#pragma once\n\n#include <array>\n#include <cstddef>\n#include <string_view>\n\n"
   "namespace rivet_app {\n\n"
   "// One row per user-visible key: the key plus the zh and en strings from\n"
   "// the project's shared/i18n single source. The host loader consults the\n"
   "// active language, falls back to the other language, then to the key.\n"
   "struct I18nEntry {\n  std::string_view key;\n  std::string_view zh;\n  std::string_view en;\n};\n\n"
   (format "inline constexpr std::array<I18nEntry, ~a> kI18nTable{{\n"
           (length table))
   (string-join
    (for/list ([row (in-list table)])
      (format "    {~a, ~a, ~a}"
              (cpp-string-view-literal (car row))
              (cpp-string-view-literal (list-ref (cdr row) 0))
              (cpp-string-view-literal (list-ref (cdr row) 1))))
    ",\n")
   "\n}};\n\n}  // namespace rivet_app\n"))

(define (swift-i18n-source table)
  (string-append
   "// Generated by Rivet. Do not edit by hand.\n"
   "import Foundation\n\n"
   "// One row per user-visible key from the project's shared/i18n single\n"
   "// source; tr() consults the active language, the other language, then the\n"
   "// key, mirroring the C++ loaders byte for byte.\n"
   "enum GeneratedI18n {\n"
   "    static let table: [String: [String: String]] = [\n"
   (string-join
    (for/list ([row (in-list table)])
      (format "        ~a: [\"zh\": ~a, \"en\": ~a]"
              (swift-string-literal-value (car row))
              (swift-string-literal-value (list-ref (cdr row) 0))
              (swift-string-literal-value (list-ref (cdr row) 1))))
    ",\n")
   ",\n    ]\n\n"
   "    static func tr(_ language: String, _ key: String) -> String {\n"
   "        guard let row = table[key] else { return key }\n"
   "        let active = row[language] ?? \"\"\n"
   "        if !active.isEmpty { return active }\n"
   "        let other = row[language == \"zh\" ? \"en\" : \"zh\"] ?? \"\"\n"
   "        if !other.isEmpty { return other }\n"
   "        return key\n"
   "    }\n"
   "}\n"))

(define (write-generated! path content)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace
    (lambda (out) (display content out))))

;; Computes the embedded tables as (path . content) pairs without touching
;; the disk — the same plan/writer split as codegen's client-outputs, so the
;; release gate and the writer can never disagree about a fresh tree.
(define (i18n-outputs project)
  (define table (load-i18n-table project))
  (when (null? table)
    (error 'i18n "the i18n tables are empty; add keys to shared/i18n"))
  (define outputs
    (list*
     (cons (project-path project "macos-host" "Sources" "RivetHost"
                         "GeneratedI18n.swift")
           (swift-i18n-source table))
     (cons (project-path project "windows" "GeneratedI18n.hpp")
           (cpp-i18n-header table))
     (let ([linux-host (project-path project "linux")])
       (if (directory-exists? linux-host)
           (list (cons (build-path linux-host "GeneratedI18n.hpp")
                       (cpp-i18n-header table)))
           '()))))
  (cons outputs (length table)))

(define (generate-i18n! project)
  (define plan (i18n-outputs project))
  (for ([pair (in-list (car plan))])
    (write-generated! (car pair) (cdr pair)))
  (list (cdr plan) (length (car plan))))

;; The release-gate variant: returns the stale/missing lists, or #f when the
;; project keeps no shared/i18n directory (nothing to gate).
(define (check-generated-i18n project)
  (define shared-dir (project-path project "shared" "i18n"))
  (and (directory-exists? shared-dir)
       (let ([outputs (car (i18n-outputs project))])
         (define stale '())
         (define missing '())
         (for ([pair (in-list outputs)])
           (cond
             [(not (file-exists? (car pair)))
              (set! missing (cons (car pair) missing))]
             [(not (string=? (file->string (car pair)) (cdr pair)))
              (set! stale (cons (car pair) stale))]))
         (if (and (null? stale) (null? missing))
             #f
             (hash 'stale (reverse stale) 'missing (reverse missing))))))
