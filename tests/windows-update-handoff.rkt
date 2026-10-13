#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "..")
(define source
  (file->string
   (build-path repository-root "platform" "windows" "update"
               "update_handoff.cpp")))
(define project
  (file->string
   (build-path repository-root "platform" "windows" "rivet-host.vcxproj")))

(for ([required (in-list '("tasklist /FI"
                           "msiexec /passive /norestart"
                           "process-exit-timeout"
                           "msiexec-failed-"
                           "GetCurrentProcessId"
                           "CreateProcessW"
                           "release_lease"
                           "1641"
                           "3010"))])
  (check-true (string-contains? source required)
              (format "Windows handoff lost required lifecycle step: ~a"
                      required)))
(check-true (string-contains? project "update\\update_handoff.cpp")
            "the released Windows platform library must compile the handoff")
(check-true (string-contains? project "Debug|ARM64"))
(check-true (string-contains? project "Release|ARM64"))
