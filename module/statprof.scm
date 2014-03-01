;;;; (statprof) -- a statistical profiler for Guile
;;;; -*-scheme-*-
;;;;
;;;; 	Copyright (C) 2009, 2010, 2011, 2013, 2014  Free Software Foundation, Inc.
;;;;    Copyright (C) 2004, 2009 Andy Wingo <wingo at pobox dot com>
;;;;    Copyright (C) 2001 Rob Browning <rlb at defaultvalue dot org>
;;;; 
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;; 
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU Lesser General Public
;;;; License along with this library; if not, write to the Free Software
;;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;;;; 


;;; Commentary:
;;;
;;; @code{(statprof)} is a statistical profiler for Guile.
;;;
;;; A simple use of statprof would look like this:
;;;
;;; @example
;;;   (statprof (lambda () (do-something))
;;;             #:hz 100
;;;             #:count-calls? #t)
;;; @end example
;;;
;;; This would run the thunk with statistical profiling, finally
;;; displaying a gprof flat-style table of statistics which could
;;; something like this:
;;;
;;; @example
;;;   %   cumulative      self              self    total
;;;  time    seconds   seconds    calls  ms/call  ms/call  name
;;;  35.29      0.23      0.23     2002     0.11     0.11  -
;;;  23.53      0.15      0.15     2001     0.08     0.08  positive?
;;;  23.53      0.15      0.15     2000     0.08     0.08  +
;;;  11.76      0.23      0.08     2000     0.04     0.11  do-nothing
;;;   5.88      0.64      0.04     2001     0.02     0.32  loop
;;;   0.00      0.15      0.00        1     0.00   150.59  do-something
;;;  ...
;;; @end example
;;;
;;; All of the numerical data with the exception of the calls column is
;;; statistically approximate. In the following column descriptions, and
;;; in all of statprof, "time" refers to execution time (both user and
;;; system), not wall clock time.
;;;
;;; @table @asis
;;; @item % time
;;; The percent of the time spent inside the procedure itself
;;; (not counting children).
;;; @item cumulative seconds
;;; The total number of seconds spent in the procedure, including
;;; children.
;;; @item self seconds
;;; The total number of seconds spent in the procedure itself (not counting
;;; children).
;;; @item calls
;;; The total number of times the procedure was called.
;;; @item self ms/call
;;; The average time taken by the procedure itself on each call, in ms.
;;; @item total ms/call
;;; The average time taken by each call to the procedure, including time
;;; spent in child functions.
;;; @item name
;;; The name of the procedure.
;;; @end table
;;;
;;; The profiler uses @code{eq?} and the procedure object itself to
;;; identify the procedures, so it won't confuse different procedures with
;;; the same name. They will show up as two different rows in the output.
;;;
;;; Right now the profiler is quite simplistic.  I cannot provide
;;; call-graphs or other higher level information.  What you see in the
;;; table is pretty much all there is. Patches are welcome :-)
;;;
;;; @section Implementation notes
;;;
;;; The profiler works by setting the unix profiling signal
;;; @code{ITIMER_PROF} to go off after the interval you define in the call
;;; to @code{statprof-reset}. When the signal fires, a sampling routine is
;;; run which looks at the current procedure that's executing, and then
;;; crawls up the stack, and for each procedure encountered, increments
;;; that procedure's sample count. Note that if a procedure is encountered
;;; multiple times on a given stack, it is only counted once. After the
;;; sampling is complete, the profiler resets profiling timer to fire
;;; again after the appropriate interval.
;;;
;;; Meanwhile, the profiler keeps track, via @code{get-internal-run-time},
;;; how much CPU time (system and user -- which is also what
;;; @code{ITIMER_PROF} tracks), has elapsed while code has been executing
;;; within a statprof-start/stop block.
;;;
;;; The profiler also tries to avoid counting or timing its own code as
;;; much as possible.
;;;
;;; Code:

(define-module (statprof)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:autoload   (ice-9 format) (format)
  #:use-module (system vm vm)
  #:use-module (system vm frame)
  #:use-module (system vm debug)
  #:use-module (system vm program)
  #:export (statprof-active?
            statprof-start
            statprof-stop
            statprof-reset

            statprof-accumulated-time
            statprof-sample-count
            statprof-fold-call-data
            statprof-proc-call-data
            statprof-call-data-name
            statprof-call-data-calls
            statprof-call-data-cum-samples
            statprof-call-data-self-samples
            statprof-call-data->stats
           
            statprof-stats-proc-name
            statprof-stats-proc-source
            statprof-stats-%-time-in-proc
            statprof-stats-cum-secs-in-proc
            statprof-stats-self-secs-in-proc
            statprof-stats-calls
            statprof-stats-self-secs-per-call
            statprof-stats-cum-secs-per-call

            statprof-display
            statprof-display-anomalies
            statprof-display-anomolies ; Deprecated spelling.

            statprof-fetch-stacks
            statprof-fetch-call-tree

            statprof
            with-statprof

            gcprof))


;; This profiler tracks two numbers for every function called while
;; it's active.  It tracks the total number of calls, and the number
;; of times the function was active when the sampler fired.
;;
;; Globally the profiler tracks the total time elapsed and the number
;; of times the sampler was fired.
;;
;; Right now, this profiler is not per-thread and is not thread safe.

(define-record-type <state>
  (make-state accumulated-time last-start-time sample-count
              sampling-period remaining-prof-time profile-level
              call-counts gc-time-taken inside-profiler?
              prev-sigprof-handler buffer buffer-pos)
  state?
  ;; Total time so far.
  (accumulated-time accumulated-time set-accumulated-time!)
  ;; Start-time when timer is active.
  (last-start-time last-start-time set-last-start-time!)
  ;; Total count of sampler calls.
  (sample-count sample-count set-sample-count!)
  ;; Microseconds.
  (sampling-period sampling-period set-sampling-period!)
  ;; Time remaining when prof suspended.
  (remaining-prof-time remaining-prof-time set-remaining-prof-time!)
  ;; For user start/stop nesting.
  (profile-level profile-level set-profile-level!)
  ;; Hash table mapping ip -> call count, or #f if not counting calls.
  (call-counts call-counts set-call-counts!)
  ;; GC time between statprof-start and statprof-stop.
  (gc-time-taken gc-time-taken set-gc-time-taken!)
  ;; True if we are inside the profiler.
  (inside-profiler? inside-profiler? set-inside-profiler?!)
  ;; True if we are inside the profiler.
  (prev-sigprof-handler prev-sigprof-handler set-prev-sigprof-handler!)
  ;; Stack samples.
  (buffer buffer set-buffer!)
  (buffer-pos buffer-pos set-buffer-pos!))

(define profiler-state (make-parameter #f))

(define (fresh-buffer)
  (make-vector 1024 #f))

(define (expand-buffer buf)
  (let* ((size (vector-length buf))
         (new (make-vector (* size 2) #f)))
    (vector-move-left! buf 0 (vector-length buf) new 0)
    new))

(define* (fresh-profiler-state #:key (count-calls? #f)
                               (sampling-period 10000))
  (make-state 0 #f 0
              sampling-period 0 0
              (and count-calls? (make-hash-table)) 0 #f
              #f (fresh-buffer) 0))

(define (ensure-profiler-state)
  (or (profiler-state)
      (let ((state (fresh-profiler-state)))
        (profiler-state state)
        state)))

(define (existing-profiler-state)
  (or (profiler-state)
      (error "expected there to be a profiler state")))

(define (accumulate-time state stop-time)
  (set-accumulated-time! state
                         (+ (accumulated-time state)
                            (- stop-time (last-start-time state)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; SIGPROF handler

(define (sample-stack-procs state stack)
  (set-sample-count! state (+ (sample-count state) 1))

  (let lp ((frame (stack-ref stack 0))
           (buffer (buffer state))
           (pos (buffer-pos state)))
    (define (write-sample sample)
      (vector-set! buffer pos sample))
    (define (continue pos)
      (lp (frame-previous frame) buffer pos))
    (define (write-sample-and-continue sample)
      (write-sample sample)
      (continue (1+ pos)))
    (cond
     ((= pos (vector-length buffer))
      (lp frame (expand-buffer buffer) pos))
     ((not frame)
      (write-sample #f)
      (set-buffer! state buffer)
      (set-buffer-pos! state (1+ pos)))
     (else
      (let ((proc (frame-procedure frame)))
        (cond
         ((primitive? proc)
          (write-sample-and-continue (procedure-name proc)))
         ((program? proc)
          (write-sample-and-continue (frame-instruction-pointer frame)))
         (proc (write-sample-and-continue proc))
         ;; If proc is false, that would confuse our stack walker.
         ;; Ignore it.
         (else (continue pos))))))))

(define (reset-sigprof-timer usecs)
  ;; Guile's setitimer binding is terrible.
  (let ((prev (setitimer ITIMER_PROF 0 0 0 usecs)))
    (+ (* (caadr prev) #e1e6) (cdadr prev))))

(define (profile-signal-handler sig)
  (define state (existing-profiler-state))

  (set-inside-profiler?! state #t)

  ;; FIXME: with-statprof should be able to set an outer frame for the
  ;; stack cut
  (when (positive? (profile-level state))
    (let* ((stop-time (get-internal-run-time))
           ;; cut down to the signal handler. note that this will only
           ;; work if statprof.scm is compiled; otherwise we get
           ;; `eval' on the stack instead, because if it's not
           ;; compiled, profile-signal-handler is a thunk that
           ;; tail-calls eval. perhaps we should always compile the
           ;; signal handler instead...
           (stack (or (make-stack #t profile-signal-handler)
                      (pk 'what! (make-stack #t)))))

      (sample-stack-procs state stack)
      (accumulate-time state stop-time)
      (set-last-start-time! state (get-internal-run-time))

      (reset-sigprof-timer (sampling-period state))))
  
  (set-inside-profiler?! state #f))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Count total calls.

(define (count-call frame)
  (let ((state (existing-profiler-state)))
    (unless (inside-profiler? state)
      (accumulate-time state (get-internal-run-time))

      (let* ((key (let ((proc (frame-procedure frame)))
                    (cond
                     ((primitive? proc) (procedure-name proc))
                     ((program? proc) (program-code proc))
                     (else proc))))
             (handle (hashv-create-handle! (call-counts state) key 0)))
        (set-cdr! handle (1+ (cdr handle))))

      (set-last-start-time! state (get-internal-run-time)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (statprof-active?)
  "Returns @code{#t} if @code{statprof-start} has been called more times
than @code{statprof-stop}, @code{#f} otherwise."
  (define state (profiler-state))
  (and state (positive? (profile-level state))))

;; Do not call this from statprof internal functions -- user only.
(define* (statprof-start #:optional (state (ensure-profiler-state)))
  "Start the profiler.@code{}"
  ;; After some head-scratching, I don't *think* I need to mask/unmask
  ;; signals here, but if I'm wrong, please let me know.
  (set-profile-level! state (+ (profile-level state) 1))
  (when (= (profile-level state) 1)
    (let ((rpt (remaining-prof-time state)))
      (set-remaining-prof-time! state 0)
      ;; FIXME: Use per-thread run time.
      (set-last-start-time! state (get-internal-run-time))
      (set-gc-time-taken! state (assq-ref (gc-stats) 'gc-time-taken))
      (let ((prev (sigaction SIGPROF profile-signal-handler)))
        (set-prev-sigprof-handler! state (car prev)))
      (reset-sigprof-timer (if (zero? rpt) (sampling-period state) rpt))
      (when (call-counts state)
        (add-hook! (vm-apply-hook) count-call))
      (set-vm-trace-level! (1+ (vm-trace-level)))
      #t)))
  
;; Do not call this from statprof internal functions -- user only.
(define* (statprof-stop #:optional (state (ensure-profiler-state)))
  "Stop the profiler.@code{}"
  ;; After some head-scratching, I don't *think* I need to mask/unmask
  ;; signals here, but if I'm wrong, please let me know.
  (set-profile-level! state (- (profile-level state) 1))
  (when (zero? (profile-level state))
    (set-gc-time-taken! state
                        (- (assq-ref (gc-stats) 'gc-time-taken)
                           (gc-time-taken state)))
    (set-vm-trace-level! (1- (vm-trace-level)))
    (when (call-counts state)
      (remove-hook! (vm-apply-hook) count-call))
    ;; I believe that we need to do this before getting the time
    ;; (unless we want to make things even more complicated).
    (set-remaining-prof-time! state (reset-sigprof-timer 0))
    (accumulate-time state (get-internal-run-time))
    (sigaction SIGPROF (prev-sigprof-handler state))
    (set-prev-sigprof-handler! state #f)
    (set-last-start-time! state #f)))

(define* (statprof-reset sample-seconds sample-microseconds count-calls?
                         #:optional full-stacks?)
  "Reset the statprof sampler interval to @var{sample-seconds} and
@var{sample-microseconds}. If @var{count-calls?} is true, arrange to
instrument procedure calls as well as collecting statistical profiling
data.  (The optional @var{full-stacks?} argument is deprecated; statprof
always collects full stacks.)"
  (when (statprof-active?)
    (error "Can't reset profiler while profiler is running."))
  (profiler-state
   (fresh-profiler-state #:count-calls? count-calls?
                         #:sampling-period (+ (* sample-seconds #e1e6)
                                              sample-microseconds)))
  (values))

(define-record-type call-data
  (make-call-data name printable source
                  call-count cum-sample-count self-sample-count)
  call-data?
  (name call-data-name)
  (printable call-data-printable)
  (source call-data-source)
  (call-count call-data-call-count set-call-data-call-count!)
  (cum-sample-count call-data-cum-sample-count set-call-data-cum-sample-count!)
  (self-sample-count call-data-self-sample-count set-call-data-self-sample-count!))

(define (source->string source)
  (format #f "~a:~a:~a"
          (or (source-file source) "<current input>")
          (source-line-for-user source)
          (source-column source)))

(define (program-debug-info-printable pdi)
  (let* ((addr (program-debug-info-addr pdi))
         (name (or (and=> (program-debug-info-name pdi) symbol->string)
                   (string-append "#x" (number->string addr 16))))
         (loc (and=> (find-source-for-addr addr) source->string)))
    (if loc
        (string-append name " at " loc)
        name)))

(define (addr->pdi addr cache)
  (cond
   ((hashv-get-handle cache addr) => cdr)
   (else
    (let ((data (find-program-debug-info addr)))
      (hashv-set! cache addr data)
      data))))

(define (addr->printable addr pdi)
  (or (and=> (and=> pdi program-debug-info-name) symbol->string)
      (string-append "anon #x" (number->string addr 16))))

(define (inc-call-data-cum-sample-count! cd)
  (set-call-data-cum-sample-count! cd (1+ (call-data-cum-sample-count cd))))
(define (inc-call-data-self-sample-count! cd)
  (set-call-data-self-sample-count! cd (1+ (call-data-self-sample-count cd))))

(define (stack-samples->procedure-data state)
  (let ((table (make-hash-table))
        (addr-cache (make-hash-table))
        (call-counts (call-counts state))
        (buffer (buffer state))
        (len (buffer-pos state)))
    (define (addr->call-data addr)
      (let* ((pdi (addr->pdi addr addr-cache))
             (entry (if pdi (program-debug-info-addr pdi) addr)))
        (or (hashv-ref table entry)
            (let ((data (make-call-data (and=> pdi program-debug-info-name)
                                        (addr->printable entry pdi)
                                        (find-source-for-addr entry)
                                        (and call-counts
                                             (hashv-ref call-counts entry))
                                        0
                                        0)))
              (hashv-set! table entry data)
              data))))

    (define (callee->call-data callee)
      (cond
       ((number? callee) (addr->call-data callee))
       ((hashv-ref table callee))
       (else
        (let ((data (make-call-data
                     (cond ((procedure? callee) (procedure-name callee))
                           ;; a primitive
                           ((symbol? callee) callee)
                           (else #f))
                     (with-output-to-string (lambda () (write callee)))
                     #f
                     (and call-counts (hashv-ref call-counts callee))
                     0
                     0)))
          (hashv-set! table callee data)
          data))))

    (when call-counts
      (hash-for-each (lambda (callee count)
                       (callee->call-data callee))
                     call-counts))

    (let visit-stacks ((pos 0))
      (cond
       ((< pos len)
        ;; FIXME: if we are counting all procedure calls, and
        ;; count-call is on the stack, we need to not count the part
        ;; of the stack that is within count-call.
        (inc-call-data-self-sample-count!
         (callee->call-data (vector-ref buffer pos)))
        (let visit-stack ((pos pos))
          (cond
           ((vector-ref buffer pos)
            => (lambda (callee)
                 (inc-call-data-cum-sample-count! (callee->call-data callee))
                 (visit-stack (1+ pos))))
           (else
            (visit-stacks (1+ pos))))))
       (else table)))))

(define (stack-samples->callee-lists state)
  (let ((buffer (buffer state))
        (len (buffer-pos state)))
    (let visit-stacks ((pos 0) (out '()))
      (cond
       ((< pos len)
        ;; FIXME: if we are counting all procedure calls, and
        ;; count-call is on the stack, we need to not count the part
        ;; of the stack that is within count-call.
        (let visit-stack ((pos pos) (stack '()))
          (cond
           ((vector-ref buffer pos)
            => (lambda (callee)
                 (visit-stack (1+ pos) (cons callee stack))))
           (else
            (visit-stacks (1+ pos) (cons (reverse stack) out))))))
       (else (reverse out))))))

(define (statprof-fold-call-data proc init)
  "Fold @var{proc} over the call-data accumulated by statprof. Cannot be
called while statprof is active. @var{proc} should take two arguments,
@code{(@var{call-data} @var{prior-result})}.

Note that a given proc-name may appear multiple times, but if it does,
it represents different functions with the same name."
  (when (statprof-active?)
    (error "Can't call statprof-fold-call-data while profiler is running."))
  (hash-fold
   (lambda (key value prior-result)
     (proc value prior-result))
   init
   (stack-samples->procedure-data (existing-profiler-state))))

(define (statprof-proc-call-data proc)
  "Returns the call-data associated with @var{proc}, or @code{#f} if
none is available."
  (when (statprof-active?)
    (error "Can't call statprof-proc-call-data while profiler is running."))
  (hashv-ref (stack-samples->procedure-data (existing-profiler-state))
             (cond
              ((primitive? proc) (procedure-name proc))
              ((program? proc) (program-code proc))
              (else (program-code proc)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Stats

(define-record-type stats
  (make-stats proc-name proc-source
              %-time-in-proc cum-secs-in-proc self-secs-in-proc
              calls self-secs-per-call cum-secs-per-call)
  stats?
  (proc-name statprof-stats-proc-name)
  (proc-source statprof-stats-proc-source)
  (%-time-in-proc statprof-stats-%-time-in-proc)
  (cum-secs-in-proc statprof-stats-cum-secs-in-proc)
  (self-secs-in-proc statprof-stats-self-secs-in-proc)
  (calls statprof-stats-calls)
  (self-secs-per-call statprof-stats-self-secs-per-call)
  (cum-secs-per-call statprof-stats-cum-secs-per-call))

(define (statprof-call-data->stats call-data)
  "Returns an object of type @code{statprof-stats}."
  (define state (existing-profiler-state))

  (let* ((proc-name (call-data-name call-data))
         (proc-source (and=> (call-data-source call-data) source->string))
         (self-samples (call-data-self-sample-count call-data))
         (cum-samples (call-data-cum-sample-count call-data))
         (all-samples (statprof-sample-count))
         (secs-per-sample (/ (statprof-accumulated-time)
                             (statprof-sample-count)))
         (num-calls (and (call-counts state)
                         (statprof-call-data-calls call-data))))

    (make-stats (or proc-name
                    ;; If there is no name and no source, fall back to
                    ;; printable.
                    (and (not proc-source) (call-data-printable call-data)))
                proc-source
                (* (/ self-samples all-samples) 100.0)
                (* cum-samples secs-per-sample 1.0)
                (* self-samples secs-per-sample 1.0)
                num-calls
                (and num-calls ;; maybe we only sampled in children
                     (if (zero? self-samples) 0.0
                         (/ (* self-samples secs-per-sample) 1.0 num-calls)))
                (and num-calls ;; cum-samples must be positive
                     (/ (* cum-samples secs-per-sample)
                        1.0
                        ;; num-calls might be 0 if we entered statprof during the
                        ;; dynamic extent of the call
                        (max num-calls 1))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (stats-sorter x y)
  (let ((diff (- (statprof-stats-self-secs-in-proc x)
                 (statprof-stats-self-secs-in-proc y))))
    (positive?
     (if (= diff 0)
         (- (statprof-stats-cum-secs-in-proc x)
            (statprof-stats-cum-secs-in-proc y))
         diff))))

(define* (statprof-display #:optional (port (current-output-port))
                           (state (existing-profiler-state)))
  "Displays a gprof-like summary of the statistics collected. Unless an
optional @var{port} argument is passed, uses the current output port."
  (cond
   ((zero? (statprof-sample-count))
    (format port "No samples recorded.\n"))
   (else
    (let* ((stats-list (statprof-fold-call-data
                        (lambda (data prior-value)
                          (cons (statprof-call-data->stats data)
                                prior-value))
                        '()))
           (sorted-stats (sort stats-list stats-sorter)))

      (define (display-stats-line stats)
        (format port "~6,2f ~9,2f ~9,2f"
                (statprof-stats-%-time-in-proc stats)
                (statprof-stats-cum-secs-in-proc stats)
                (statprof-stats-self-secs-in-proc stats))
        (if (call-counts state)
            (if (statprof-stats-calls stats)
                (format port " ~7d ~8,2f ~8,2f  "
                        (statprof-stats-calls stats)
                        (* 1000 (statprof-stats-self-secs-per-call stats))
                        (* 1000 (statprof-stats-cum-secs-per-call stats)))
                (format port "                            "))
            (display "  " port))
        (let ((source (statprof-stats-proc-source stats))
              (name (statprof-stats-proc-name stats)))
          (when source
            (display source port)
            (when name
              (display ":" port)))
          (when name
            (display name port))
          (newline port)))
    
      (if (call-counts state)
          (begin
            (format  port "~5a ~10a   ~7a ~8a ~8a ~8a  ~8@a\n"
                     "%  " "cumulative" "self" "" "self" "total" "")
            (format  port "~5a  ~9a  ~8a ~8a ~8a ~8a  ~a\n"
                     "time" "seconds" "seconds" "calls" "ms/call" "ms/call" "procedure"))
          (begin
            (format  port "~5a ~10a   ~7a  ~8a\n"
                     "%" "cumulative" "self" "")
            (format  port "~5a  ~10a  ~7a  ~a\n"
                     "time" "seconds" "seconds" "procedure")))

      (for-each display-stats-line sorted-stats)

      (display "---\n" port)
      (simple-format #t "Sample count: ~A\n" (statprof-sample-count))
      (simple-format #t "Total time: ~A seconds (~A seconds in GC)\n"
                     (statprof-accumulated-time)
                     (/ (gc-time-taken state)
                        1.0 internal-time-units-per-second))))))

(define* (statprof-display-anomalies #:optional (state
                                                 (existing-profiler-state)))
  "A sanity check that attempts to detect anomalies in statprof's
statistics.@code{}"
  (statprof-fold-call-data
   (lambda (data prior-value)
     (when (and (call-counts state)
                (zero? (call-data-call-count data))
                (positive? (call-data-cum-sample-count data)))
       (simple-format #t
                      "==[~A ~A ~A]\n"
                      (call-data-name data)
                      (call-data-call-count data)
                      (call-data-cum-sample-count data))))
   #f)
  (simple-format #t "Total time: ~A\n" (statprof-accumulated-time))
  (simple-format #t "Sample count: ~A\n" (statprof-sample-count)))

(define (statprof-display-anomolies)
  (issue-deprecation-warning "statprof-display-anomolies is a misspelling. "
                             "Use statprof-display-anomalies instead.")
  (statprof-display-anomalies))

(define* (statprof-accumulated-time #:optional (state
                                                (existing-profiler-state)))
  "Returns the time accumulated during the last statprof run.@code{}"
  (/ (accumulated-time state) 1.0 internal-time-units-per-second))

(define* (statprof-sample-count #:optional (state (existing-profiler-state)))
  "Returns the number of samples taken during the last statprof run.@code{}"
  (sample-count state))

(define statprof-call-data-name call-data-name)
(define statprof-call-data-calls call-data-call-count)
(define statprof-call-data-cum-samples call-data-cum-sample-count)
(define statprof-call-data-self-samples call-data-self-sample-count)

(define* (statprof-fetch-stacks #:optional (state (existing-profiler-state)))
  "Returns a list of stacks, as they were captured since the last call
to @code{statprof-reset}."
  (stack-samples->callee-lists state))

(define procedure=?
  (lambda (a b)
    (cond
     ((eq? a b))
     ((and (program? a) (program? b))
      (eq? (program-code a) (program-code b)))
     (else
      #f))))

;; tree ::= (car n . tree*)

(define (lists->trees lists equal?)
  (let lp ((in lists) (n-terminal 0) (tails '()))
    (cond
     ((null? in)
      (let ((trees (map (lambda (tail)
                          (cons (car tail)
                                (lists->trees (cdr tail) equal?)))
                        tails)))
        (cons (apply + n-terminal (map cadr trees))
              (sort trees
                    (lambda (a b) (> (cadr a) (cadr b)))))))
     ((null? (car in))
      (lp (cdr in) (1+ n-terminal) tails))
     ((find (lambda (x) (equal? (car x) (caar in)))
            tails)
      => (lambda (tail)
           (lp (cdr in)
               n-terminal
               (assq-set! tails
                          (car tail)
                          (cons (cdar in) (cdr tail))))))
     (else
      (lp (cdr in)
          n-terminal
          (acons (caar in) (list (cdar in)) tails))))))

(define* (statprof-fetch-call-tree #:optional (state (existing-profiler-state)))
  "Return a call tree for the previous statprof run.

The return value is a list of nodes, each of which is of the type:
@code
 node ::= (@var{proc} @var{count} . @var{nodes})
@end code"
  (define (callee->printable callee)
    (cond
     ((number? callee)
      (addr->printable callee (find-program-debug-info callee)))
     (else
      (with-output-to-string (lambda () (write callee))))))
  (define (memoizev/1 proc table)
    (lambda (x)
      (cond
       ((hashv-get-handle table x) => cdr)
       (else
        (let ((res (proc x)))
          (hashv-set! table x res)
          res)))))
  (let ((callee->printable (memoizev/1 callee->printable (make-hash-table))))
    (cons #t (lists->trees (map (lambda (callee-list)
                                  (map callee->printable callee-list))
                                (stack-samples->callee-lists state))
                           equal?))))

(define* (statprof thunk #:key (loop 1) (hz 100) (count-calls? #f)
                   (port (current-output-port)) full-stacks?)
  "Profiles the execution of @var{thunk}.

The stack will be sampled @var{hz} times per second, and the thunk itself will
be called @var{loop} times.

If @var{count-calls?} is true, all procedure calls will be recorded. This
operation is somewhat expensive."
  
  (let ((state (fresh-profiler-state #:count-calls? count-calls?
                                     #:sampling-period
                                     (inexact->exact (round (/ 1e6 hz))))))
    (parameterize ((profiler-state state))
      (dynamic-wind
        (lambda ()
          (statprof-start state))
        (lambda ()
          (let lp ((i loop))
            (unless (zero? i)
              (thunk)
              (lp (1- i)))))
        (lambda ()
          (statprof-stop state)
          (statprof-display port state))))))

(define-macro (with-statprof . args)
  "Profiles the expressions in its body.

Keyword arguments:

@table @code
@item #:loop
Execute the body @var{loop} number of times, or @code{#f} for no looping

default: @code{#f}
@item #:hz
Sampling rate

default: @code{20}
@item #:count-calls?
Whether to instrument each function call (expensive)

default: @code{#f}
@end table"
  (define (kw-arg-ref kw args def)
    (cond
     ((null? args) (error "Invalid macro body"))
     ((keyword? (car args))
      (if (eq? (car args) kw)
          (cadr args)
          (kw-arg-ref kw (cddr args) def)))
     ((eq? kw #f def) ;; asking for the body
      args)
     (else def))) ;; kw not found
  `((@ (statprof) statprof)
    (lambda () ,@(kw-arg-ref #f args #f))
    #:loop ,(kw-arg-ref #:loop args 1)
    #:hz ,(kw-arg-ref #:hz args 100)
    #:count-calls? ,(kw-arg-ref #:count-calls? args #f)
    #:full-stacks? ,(kw-arg-ref #:full-stacks? args #f)))

(define* (gcprof thunk #:key (loop 1) full-stacks?)
  "Do an allocation profile of the execution of @var{thunk}.

The stack will be sampled soon after every garbage collection, yielding
an approximate idea of what is causing allocation in your program.

Since GC does not occur very frequently, you may need to use the
@var{loop} parameter, to cause @var{thunk} to be called @var{loop}
times."
  
  (let ((state (fresh-profiler-state)))
    (parameterize ((profiler-state state))
      (define (gc-callback)
        (unless (inside-profiler? state)
          (set-inside-profiler?! state #t)

          ;; FIXME: should be able to set an outer frame for the stack cut
          (let ((stop-time (get-internal-run-time))
                ;; Cut down to gc-callback, and then one before (the
                ;; after-gc async).  See the note in profile-signal-handler
                ;; also.
                (stack (or (make-stack #t gc-callback 0 1)
                           (pk 'what! (make-stack #t)))))
            (sample-stack-procs state stack)
            (accumulate-time state stop-time)
            (set-last-start-time! state (get-internal-run-time)))

          (set-inside-profiler?! state #f)))

      (dynamic-wind
        (lambda ()
          (set-profile-level! state 1)
          (set-last-start-time! state (get-internal-run-time))
          (set-gc-time-taken! state (assq-ref (gc-stats) 'gc-time-taken))
          (add-hook! after-gc-hook gc-callback))
        (lambda ()
          (let lp ((i loop))
            (unless (zero? i)
              (thunk)
              (lp (1- i)))))
        (lambda ()
          (remove-hook! after-gc-hook gc-callback)
          (set-gc-time-taken! state
                              (- (assq-ref (gc-stats) 'gc-time-taken)
                                 (gc-time-taken state)))
          (accumulate-time state (get-internal-run-time))
          (set-profile-level! state 0)
          (statprof-display))))))
