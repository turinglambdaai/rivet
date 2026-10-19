#lang racket/base

;; Linkable host packages must carry the implementation units behind every
;; public widget. Compiling chart_area/rivet_chart_control without the shared
;; chart codec/model passed compilation but failed only when a downstream
;; executable linked (#237 pre-release gate).

(require rackunit
         racket/file
         racket/list
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root "../..")
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
(define windows-source-props
  (file->string
   (build-path repository-root "platform" "windows"
               "rivet-runtime-sources.props")))
(define runtime-cmake
  (file->string
   (build-path repository-root "runtime" "CMakeLists.txt")))
(define windows-host-template
  (file->string
   (build-path repository-root "platform" "windows" "host"
               "RivetHost.vcxproj")))
(define windows-chart-header
  (file->string
   (build-path repository-root "platform" "windows" "chart"
               "rivet_chart_control.hpp")))
(define windows-chart-source
  (file->string
   (build-path repository-root "platform" "windows" "chart"
               "rivet_chart_control.cpp")))
(define taskboard-window-header
  (file->string
   (build-path repository-root "examples" "taskboard" "windows"
               "MainWindow.xaml.h")))
(define taskboard-window-source
  (file->string
   (build-path repository-root "examples" "taskboard" "windows"
               "MainWindow.xaml.cpp")))

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

;; The Windows runtime source list has exactly one author (issue #280): the
;; props file that vendored hosts import. Re-listing sources in the vcxproj
;; would reintroduce the roting hand copies behind the podlens LNK2001.
(check-true (string-contains? windows-host "rivet-runtime-sources.props")
            "rivet-host.vcxproj must import the shared runtime source props")
(check-false (string-contains? windows-host "<ClCompile Include=")
             "rivet-host.vcxproj must not re-list sources beside the props")

;; Every shared runtime unit CMake compiles into rivet_protocol — minus the
;; chart unit that rivet-chart.lib owns on Windows — must appear in the props,
;; so adding a translation unit without reaching vendored Windows hosts fails
;; here instead of at a downstream link (the utf8.cpp LNK2001 class).
(define cmake-runtime-units
  (filter-map
   (lambda (line)
     (define unit-match
       (regexp-match #px"^\\s*src/([A-Za-z0-9_]+\\.cpp)\\s*$" line))
     (and unit-match (second unit-match)))
   (string-split runtime-cmake "\n")))
(check-true (pair? cmake-runtime-units)
            "runtime/CMakeLists.txt must still declare rivet_protocol sources")
(for ([unit (in-list cmake-runtime-units)]
      #:unless (string=? unit "chart_batch.cpp"))
  (check-true
   (string-contains? windows-source-props (format "runtime\\src\\~a" unit))
   (format "rivet-runtime-sources.props must compile the shared unit ~a" unit)))

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
(for ([header (in-list '("winrt/Windows.Foundation.h"
                         "winrt/Windows.Foundation.Collections.h"
                         "winrt/Windows.UI.h"))])
  (check-true (string-contains? windows-chart-header header)
              (format "the chart library must explicitly include ~a" header)))
(check-false (string-contains? windows-chart-source "#include <windows.h>")
             "the chart library must not import Win32 macros into generated WinRT headers")
(check-true (string-contains? windows-chart-source "winrt::to_hstring")
            "the chart library should use C++/WinRT's UTF-8 conversion")
(check-false (string-contains? windows-chart-source "Windows::Foundation::Color")
             "WinRT Color belongs to Windows.UI")
(check-false (string-contains? taskboard-window-source "rivet::ui::")
             "the reference app must consume the released rivet::win_ui namespace")
(check-false (string-contains? taskboard-window-header "ChartControl chart_{nullptr}")
             "the reference app must use ChartControl's public default constructor")
