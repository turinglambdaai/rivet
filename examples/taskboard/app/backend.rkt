#lang racket/base

(require racket/format
         racket/list
         racket/string
         rivet/backend
         rivet/chart
         rivet/resources)

(provide start)

;; The reference app deliberately keeps domain policy in Racket. Native hosts
;; own presentation, accessibility, window lifecycle, and system integration.
(define-enum TaskStatus (backlog active done))

(define-record BoardTask
  ([id : Int64]
   [title : String]
   [notes : String]
   [status : TaskStatus]))

(define-record ImportProgress
  ([completed : Int64]
   [total : Int64]
   [message : String]))

(define-event operation-progress : ImportProgress)
(define-event task-saved : BoardTask)

;; -- Real-time chart demo ------------------------------------------------
;;
;; Two synthetic series exercise the shared chart data plane end to end:
;; samples accumulate on the Racket side, drain as chart batches through the
;; chart-batch event, and the timing-window RPC serves the initial paint and
;; gap recovery. A native chart widget consumes the same three shapes on
;; every host platform.

(define-record TimingSeries
  ([id : String]
   [label : String]
   [color : String]
   [unit : String]))

(define-record ChartBatchEnvelope
  ([series : String]
   [batch : Bytes]))

(define-record TimingSample
  ([ts : Int64]
   [value : Int64]))

(define-record TimingWindow
  ([series : String]
   [watermark : Int64]
   [samples : (List TimingSample)]))

(define-record TimingThreshold
  ([value : Int64]
   [label : String]
   [color : String]))

(define-record TimingMarker
  ([ts : Int64]
   [label : String]))

(define-event chart-batch : ChartBatchEnvelope)

(define timing-series
  (list (make-chart-series "offset" #:capacity 8192)
        (make-chart-series "delay" #:capacity 8192)))

(define timing-specs
  (list (TimingSeries "offset" "offsetFromMaster" "#3584e4" "ns")
        (TimingSeries "delay" "meanPathDelay" "#e01b24" "ns")))

(define timing-thresholds
  (list (TimingThreshold 250 "alarm high" "#f5c211")
        (TimingThreshold -250 "alarm low" "#f5c211")))

(define timing-markers-lock (make-semaphore 1))
(define timing-markers '())

(define timing-window-ms (make-parameter 30000))
(define timing-lock (make-semaphore 1))
(define timing-thread #f)
(define timing-stop? #f)
(define timing-step 0)

(define (current-ns)
  (define ins (current-inexact-milliseconds))
  (inexact->exact (floor (* ins 1000000))))

;; Sine with drift plus noise for offset, bounded sawtooth for delay —
;; enough motion to judge redraw rate, autoscale, thresholds, and markers.
(define (timing-next-values!)
  (set! timing-step (add1 timing-step))
  (define phase (* timing-step 0.09))
  (define offset (inexact->exact (round (+ (* 260.0 (sin phase)) (* 40.0 (cos (* phase 7.0))) (- (random 41) 20)))))
  (define delay (inexact->exact (round (+ 320.0 (* 90.0 (sin (* phase 0.21)))))))
  (cons offset delay))

(define (timing-drain-and-emit! now-ns)
  (for ([series (in-list timing-series)])
    (define batch (chart-series-drain-batch! series))
    (when (positive? (chart-batch-sample-count batch))
      (chart-batch (ChartBatchEnvelope (chart-series-id series) batch))))
  ;; A marker every five seconds of stream time proves the marker channel.
  (when (and (positive? timing-step) (zero? (modulo timing-step 312)))
    (call-with-semaphore
     timing-markers-lock
     (lambda ()
       (set! timing-markers
             (append timing-markers (list (TimingMarker now-ns "step"))))))))

(define (timing-ticker)
  (let loop ()
    (define stop? (call-with-semaphore timing-lock (lambda () timing-stop?)))
    (unless stop?
      (define now-ns (current-ns))
      (define values (timing-next-values!))
      (chart-series-append! (car timing-series) (list (cons now-ns (car values))))
      (chart-series-append! (cadr timing-series) (list (cons now-ns (cdr values))))
      ;; Drain at UI cadence: three sample ticks per emitted batch.
      (when (zero? (modulo timing-step 3))
        (timing-drain-and-emit! now-ns))
      (sleep 11/1000)
      (loop))))

(define-rpc (timing-start : Bool)
  (call-with-semaphore
   timing-lock
   (lambda ()
     (cond
       [timing-thread #f]
       [else
        (set! timing-stop? #f)
        (set! timing-thread (thread timing-ticker))
        #t]))))

(define-rpc (timing-stop : Bool)
  ;; The ticker observes the flag within one sample sleep (~11ms), so no
  ;; cross-custodian kill is needed; request custodians own their threads
  ;; and timing-stop runs in a different one.
  (define worker
    (call-with-semaphore
     timing-lock
     (lambda ()
       (cond
         [timing-thread
          (set! timing-stop? #t)
          (define current timing-thread)
          (set! timing-thread #f)
          current]
         [else #f]))))
  (cond
    [worker (thread-wait worker) #t]
    [else #f]))

(define-rpc (timing-is-running : Bool)
  (call-with-semaphore timing-lock (lambda () (and timing-thread #t))))

(define-rpc (timing-set-window [span-ms : Int64] : Bool)
  (unless (<= 1000 span-ms 600000)
    (raise-arguments-error 'timing-set-window
                           "span must be between 1s and 10min"
                           "span-ms" span-ms))
  (timing-window-ms span-ms)
  #t)

(define-rpc (timing-series-specs : (List TimingSeries))
  timing-specs)

(define-rpc (timing-decoration : (List TimingThreshold))
  timing-thresholds)

(define-rpc (timing-markers-all : (List TimingMarker))
  (call-with-semaphore timing-markers-lock (lambda () timing-markers)))

(define-rpc (timing-window [series-id : String] : TimingWindow)
  (define series
    (findf (lambda (candidate) (string=? (chart-series-id candidate) series-id))
           timing-series))
  (unless series
    (raise-arguments-error 'timing-window "unknown series" "series" series-id))
  (define span-ns (* (timing-window-ms) 1000000))
  (TimingWindow
   series-id
   (chart-series-appended series)
   (for/list ([sample (in-list (chart-series-window series span-ns))])
     (TimingSample (car sample) (cdr sample)))))



(define initial-tasks
  (list
   (BoardTask 1
         "Read the architecture guide"
         "Trace native UI -> generated client -> RVT1 -> Racket."
         (TaskStatus 'done))
   (BoardTask 2
         "Make a backend change"
         "Add one typed RPC, regenerate clients, and inspect the diff."
         (TaskStatus 'active))
   (BoardTask 3
         "Run package verification"
         "Build, package, and verify before sharing the application."
         (TaskStatus 'backlog))))

(define-state tasks : (List BoardTask) initial-tasks)
(define-state selected-task-id : (Optional Int64) 2)

(define board-lock (make-semaphore 1))
(define next-task-id 4)

(define (allocate-task-id!)
  (call-with-semaphore
   board-lock
   (lambda ()
     (define id next-task-id)
     (set! next-task-id (add1 next-task-id))
     id)))

(define (task-id task)
  (record-ref task 'id))

(define (find-task id [items (state-ref tasks)])
  (findf (lambda (task) (= (task-id task) id)) items))

(define (require-task id)
  (or (find-task id)
      (error 'taskboard "task does not exist: ~a" id)))

(define (validate-text who label value #:allow-empty? [allow-empty? #f])
  (define clean (string-trim value))
  (when (and (not allow-empty?) (string=? clean ""))
    (raise-arguments-error who "text must not be empty" label value))
  (when (> (string-length clean) 4000)
    (raise-arguments-error who "text is too long" label value "limit" 4000))
  clean)

(define-rpc (list-tasks : (List BoardTask))
  (state-ref tasks))

(define-rpc (get-task [id : Int64] : (Optional BoardTask))
  (or (find-task id) (void)))

(define-rpc (select-task [id : Int64] : (Optional BoardTask))
  (define task (find-task id))
  (state-set! selected-task-id (if task id (void)))
  (or task (void)))

(define-rpc (create-task [title : String] [notes : String] : BoardTask)
  (define task
    (BoardTask (allocate-task-id!)
          (validate-text 'create-task "title" title)
          (validate-text 'create-task "notes" notes #:allow-empty? #t)
          (TaskStatus 'backlog)))
  (state-set! tasks (append (state-ref tasks) (list task)))
  (task-saved task)
  task)

(define-rpc (update-task
             [id : Int64]
             [title : String]
             [notes : String]
             [status : TaskStatus]
             : BoardTask)
  (require-task id)
  (define updated
    (BoardTask id
          (validate-text 'update-task "title" title)
          (validate-text 'update-task "notes" notes #:allow-empty? #t)
          status))
  (state-set!
   tasks
   (for/list ([task (in-list (state-ref tasks))])
     (if (= (task-id task) id) updated task)))
  (task-saved updated)
  updated)

(define-rpc (delete-task [id : Int64] : Bool)
  (define before (state-ref tasks))
  (define after
    (filter (lambda (task) (not (= (task-id task) id))) before))
  (define deleted? (< (length after) (length before)))
  (when deleted?
    (state-set! tasks after)
    (when (equal? (state-ref selected-task-id) id)
      (state-set! selected-task-id (void))))
  deleted?)

(define (sample-entry->task entry)
  (unless (hash? entry)
    (raise-arguments-error 'reload-sample-tasks
                           "sample task must be a hash"
                           "entry" entry))
  (BoardTask (allocate-task-id!)
        (validate-text 'reload-sample-tasks "title" (hash-ref entry 'title))
        (validate-text 'reload-sample-tasks
                       "notes"
                       (hash-ref entry 'notes "")
                       #:allow-empty? #t)
        (TaskStatus (hash-ref entry 'status 'backlog))))

(define-rpc (reload-sample-tasks : (List BoardTask))
  (define entries
    (call-with-input-file (resource-path "assets" "sample-tasks.rktd") read))
  (unless (list? entries)
    (error 'reload-sample-tasks "sample-tasks.rktd must contain a list"))
  (define loaded (map sample-entry->task entries))
  (state-set! tasks loaded)
  (state-set! selected-task-id
              (if (null? loaded) (void) (task-id (car loaded))))
  loaded)

;; This is intentionally bounded and cooperative. Every sleep is a cancellation
;; point because Rivet runs each RPC under its own custodian. The native clients
;; can cancel the returned request id without inventing an application protocol.
(define-rpc (generate-demo-tasks [count : Int64] : (List BoardTask))
  (unless (<= 0 count 1000)
    (raise-arguments-error 'generate-demo-tasks
                           "count must be between 0 and 1000"
                           "count" count))
  (define generated
    (for/list ([index (in-range count)])
      (when (or (= index 0)
                (= (add1 index) count)
                (zero? (modulo (add1 index) 25)))
        (operation-progress
         (ImportProgress (add1 index)
                         count
                         (~a "Preparing task " (add1 index) " of " count))))
      (sleep 0.001)
      (BoardTask (allocate-task-id!)
            (~a "Generated task " (add1 index))
            "Created by the bounded reference workload."
            (TaskStatus (case (modulo index 3)
                          [(0) 'backlog]
                          [(1) 'active]
                          [else 'done])))))
  (state-set! tasks generated)
  (state-set! selected-task-id
              (if (null? generated) (void) (task-id (car generated))))
  generated)

(define (reset-reference-state!)
  (state-set! tasks initial-tasks)
  (state-set! selected-task-id 2)
  (set! next-task-id 4)
  (timing-stop)
  (for ([series (in-list timing-series)])
    (chart-series-reset! series))
  (call-with-semaphore
   timing-markers-lock
   (lambda () (set! timing-markers '()))))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))

(module+ test-support
  (provide BoardTask
           TaskStatus
           ImportProgress
           tasks
           selected-task-id
           list-tasks
           get-task
           select-task
           create-task
           update-task
           delete-task
           reload-sample-tasks
           reset-reference-state!))
