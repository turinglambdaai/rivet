#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../rivet-cli/csharp-codegen.rkt"
         "../rivet-cli/project.rkt"
         "../rivet-cli/scaffold.rkt")

(define temp-root (make-temporary-file "rivet-csharp-codegen-~a" 'directory))

(dynamic-wind
 void
 (lambda ()
   (define project-root (create-project! "demo" temp-root))
   (call-with-output-file
    (build-path project-root "app" "backend.rkt")
    #:exists 'truncate/replace
    (lambda (out)
      (display
       #<<RKT
#lang racket/base
(require rivet/backend)
(provide start)

(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))

;; Common product-domain name that collides with System.Threading.Tasks.Task.
;; Generated async signatures must remain unambiguous without renaming it.
(define-record Task
  ([id : Int64]
   [text : String]))

(define-state selected : User (User 1 "Ada" (void)))

(define-rpc (echo-user [user : User] : User) user)
(define-rpc (find-users [query : String] : (List User)) '())
(define-rpc (get-task : Task) (Task 1 "demo"))
(define-rpc (close : Void) (void))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
RKT
       out)))

   (define project (load-project project-root))
   (define output (generate-csharp-client! project))
   (define source (file->string output))

   (check-true (regexp-match? #rx"namespace Demo\\.RivetGenerated;" source))
   (check-true (regexp-match? #rx"public sealed record User\\(long Id, string DisplayName, string\\? Nickname\\);" source))
   (check-true (regexp-match? #rx"public sealed record Task\\(long Id, string Text\\);" source))
   (check-true (regexp-match? #rx"global::System\\.Threading\\.Tasks\\.Task<User> EchoUserAsync\\(User user, CancellationToken cancellationToken = default\\)" source))
   (check-true (regexp-match? #rx"global::System\\.Threading\\.Tasks\\.Task<IReadOnlyList<User>> FindUsersAsync" source))
   (check-true (regexp-match? #rx"global::System\\.Threading\\.Tasks\\.Task<Task> GetTaskAsync" source))
   (check-true (regexp-match? #rx"global::System\\.Threading\\.Tasks\\.Task CloseAsync" source))
   (check-true (regexp-match? #rx"global::System\\.Threading\\.Tasks\\.Task<User> GetSelectedAsync" source))
   (check-true (regexp-match? #rx"global::System\\.Threading\\.Tasks\\.Task<User> SetSelectedAsync" source)))
 (lambda ()
   (when (directory-exists? temp-root)
     (delete-directory/files temp-root))))
