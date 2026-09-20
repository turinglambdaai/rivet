#lang racket/base

(require rivet/backend)

(provide start)

(define-record User
  ([id : Int64]
   [display-name : String]
   [nickname : (Optional String)]))

(define-record SearchResult
  ([items : (List User)]
   [total : Int64]))

(define-state selected : (Optional User) (void))

(define-rpc (echo-user [user : User] : User)
  user)

(define-rpc (search [query : String] : SearchResult)
  (SearchResult '() 0))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
