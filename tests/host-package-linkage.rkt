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
(define windows-host
  (file->string
   (build-path repository-root "platform" "windows"
               "rivet-host.vcxproj")))
(define windows-host-template
  (file->string
   (build-path repository-root "platform" "windows" "host"
               "RivetHost.vcxproj")))

(check-true (string-contains? linux-manifest "runtime/src/chart_batch.cpp")
            "Linux rivet::platform must link the shared chart implementation")
(check-true (string-contains? windows-chart "runtime\\src\\chart_batch.cpp")
            "Windows rivet-chart.lib must link the shared chart implementation")
(for ([project-text (in-list (list windows-host windows-chart))]
      [project-name (in-list '(rivet-host rivet-chart))])
  (check-true (string-contains? project-text "<RestoreProjectStyle>PackageReference</RestoreProjectStyle>")
              (format "~a must participate in the transitive NuGet restore graph"
                      project-name))
  (check-true
   (string-contains?
    project-text
    (format "obj\\~a\\</MSBuildProjectExtensionsPath>" project-name))
   (format "~a must have an isolated NuGet assets directory" project-name)))

(check-true
 (string-contains? windows-host-template
                   "'$(RivetSelfContained)'=='true'\">MultiThreaded")
 "self-contained Windows hosts must select the static CRT")
(check-true
 (string-contains? windows-host-template
                   "<RuntimeLibrary>$(RivetRuntimeLibrary)</RuntimeLibrary>")
 "the Windows executable must apply the same CRT setting as Rivet libraries")
(check-true
 (string-contains? windows-host-template
                   "Properties=\"RivetRuntimeLibrary=$(RivetRuntimeLibrary)\"")
 "the Windows host must forward its CRT setting to the released library")
