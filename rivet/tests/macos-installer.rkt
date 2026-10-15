#lang racket/base

(require racket/file
         net/base64
         racket/path
         racket/system
         rackunit
         "../../rivet-cli/installer.rkt"
         "../../rivet-cli/project.rkt"
         (submod "../../rivet-cli/installer.rkt" test-support))

;; ---------------------------------------------------------------------------
;; Finder layout script

(define script (dmg-style-applescript "Smoke App" "Smoke.app"))
(check-regexp-match #rx"tell disk \"Smoke App\"" script
                    "the script must address the volume by name")
(check-regexp-match
 #rx"set background picture of theViewOptions to file \"[.]background:background[.]png\""
 script
 "the background must come from the hidden .background folder")
(check-regexp-match #rx"set position of item \"Smoke[.]app\" of container window" script
                    "the bundle icon must be positioned")
(check-regexp-match #rx"set position of item \"Applications\" of container window" script
                    "the Applications link must be positioned")
(check-regexp-match #rx"set bounds of container window to \\{200, 120, 860, 520\\}" script
                    "the window must match the branded background geometry")
(check-regexp-match #rx"set icon size of theViewOptions to 80" script)

;; AppleScript strings escape volume and bundle names.
(check-regexp-match #rx"tell disk \"Smoke \\\\\"App\\\\\"\""
                    (dmg-style-applescript "Smoke \"App\"" "Smoke.app")
                    "quotes in display names must be AppleScript-escaped")

;; ---------------------------------------------------------------------------
;; Live branded DMG build (macOS hosts with Finder automation)

(module+ test
  (define hdiutil (find-executable-path "hdiutil"))
  (define osascript (find-executable-path "osascript"))

  ;; osascript talking to Finder fails fast where automation is denied; a
  ;; stuck TCC permission prompt is cut off at the probe timeout so the suite
  ;; skips instead of hanging.
  (define finder-automation?
    (and hdiutil
         osascript
         (equal? 'macosx (system-type 'os))
         (let ([probe (make-semaphore)]
               [result-box (box #f)]
               [cust (make-custodian)])
           (parameterize ([current-custodian cust])
             (thread
              (lambda ()
                (define exit-code
                  (system*/exit-code osascript
                                     "-e" "tell application \"Finder\" to get name of startup disk"))
                (set-box! result-box (zero? exit-code))
                (semaphore-post probe))))
           (define completed (sync/timeout 20 probe))
           (custodian-shutdown-all cust)
           (and completed (unbox result-box)))))

  (unless finder-automation?
    (displayln
     "rivet-macos-installer-tests: skipping the live DMG; no Finder automation")
    (exit 0))

  (define root (make-temporary-file "rivet-macos-installer-~a" 'directory))
  (define app (build-path root "Smoke.app"))
  (make-directory* (build-path app "Contents" "MacOS"))
  (void
   (call-with-output-file (build-path app "Contents" "Info.plist")
     #:exists 'truncate/replace
     (lambda (out)
       (display
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>dev.rivet.smoke</string></dict></plist>"
        out)))
   (call-with-output-file (build-path app "Contents" "MacOS" "Smoke")
     #:exists 'truncate/replace
     (lambda (out) (display "#!/bin/sh\nexit 0\n" out))))

  ;; A 1x1 PNG is enough for the live run: Finder scales the background to
  ;; the window bounds.
  (define tiny-png
    (base64-decode
     #"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
  (make-directory* (build-path root "assets"))
  (void
   (call-with-output-file (build-path root "assets" "background.png")
     #:exists 'truncate/replace
     (lambda (out) (write-bytes tiny-png out))))

  (define project
    (rivet-project root
                   (hasheq 'name "Smoke"
                           'display-name "Smoke App"
                           'version "0.1.0"
                           'dmg-background "assets/background.png")))
  (define dmg (create-macos-installer! project app #f))
  (check-true (file-exists? dmg) "the branded DMG must be produced")

  (define mnt (build-path root "inspect-mount"))
  (make-directory* mnt)
  (check-equal? (system*/exit-code hdiutil "attach" dmg
                                   "-mountpoint" (path->string mnt)
                                   "-nobrowse" "-readonly")
                0
                "the branded DMG must attach cleanly")
  (check-true (directory-exists? (build-path mnt "Smoke.app"))
              "the app bundle must sit at the volume root")
  (check-equal? (file-or-directory-type (build-path mnt "Applications") #f)
                'link
                "the Applications shortcut must be a symlink")
  (check-true (file-exists? (build-path mnt ".background" "background.png"))
              "the background asset must ride in the hidden folder")
  (check-true (file-exists? (build-path mnt ".DS_Store"))
              "the Finder styling must have written the icon layout")

  (define detach-exit
    (system*/exit-code hdiutil "detach" (path->string mnt)))
  (unless (zero? detach-exit)
    (system* hdiutil "detach" "-force" (path->string mnt)))

  ;; The scratch tree must not leak into the project between runs.
  (define dmg-2 (create-macos-installer! project app #f))
  (check-true (file-exists? dmg-2) "a re-run must overwrite the previous image")

  (delete-directory/files root #:must-exist? #f))
