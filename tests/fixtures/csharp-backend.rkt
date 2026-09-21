#lang racket/base

(require rivet/backend)

(provide start)

(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))

(define-record Task
  ([id : Int64]
   [text : String]))

(define-record SearchResult
  ([items : (List User)]
   [total : Int64]))

(define-state selected : (Optional User) (void))

(define-rpc (echo-user [user : User] : User)
  user)

(define-rpc (search [query : String] : SearchResult)
  (SearchResult (list (User 7 query (void))) 1))

(define-rpc (get-task : Task)
  (Task 1 "demo"))

(define-rpc (close : Void)
  (void))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
