#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string)

(define-runtime-path repository-root-reference "..")
(define repository-root (simplify-path repository-root-reference #t))

(define (markdown-file? path)
  (and (file-exists? path)
       (regexp-match? #rx#"[.]md$" (path->bytes path))))

(define markdown-files
  (append
   (filter markdown-file? (directory-list repository-root #:build? #t))
   (find-files markdown-file? (build-path repository-root "docs"))))

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
