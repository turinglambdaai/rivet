#lang racket/base

;; Linkable host packages must carry the implementation units behind every
;; public widget. Compiling chart_area/rivet_chart_control without the shared
;; chart codec/model passed compilation but failed only when a downstream
;; executable linked (#237 pre-release gate).

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "..")
(define linux-manifest
  (file->string
   (build-path repository-root "platform" "linux"
               "rivet_linux_sources.cmake")))
(define windows-chart
  (file->string
   (build-path repository-root "platform" "windows"
               "rivet-chart.vcxproj")))

(check-true (string-contains? linux-manifest "runtime/src/chart_batch.cpp")
            "Linux rivet::platform must link the shared chart implementation")
(check-true (string-contains? windows-chart "runtime\\src\\chart_batch.cpp")
            "Windows rivet-chart.lib must link the shared chart implementation")
