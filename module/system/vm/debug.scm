;;; Guile RTL disassembler

;;; Copyright (C) 2001, 2009, 2010, 2012, 2013 Free Software Foundation, Inc.
;;;
;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Lesser General Public
;;; License as published by the Free Software Foundation; either
;;; version 3 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Lesser General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General Public
;;; License along with this library; if not, write to the Free Software
;;; Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

;;; Code:

(define-module (system vm debug)
  #:use-module (system vm elf)
  #:use-module (system vm objcode)
  #:use-module (system foreign)
  #:use-module (rnrs bytevectors)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:export (<debug-context>
            debug-context-image
            find-debug-context
            u32-offset->addr

            <program-debug-info>
            program-debug-info-name
            program-debug-info-context
            program-debug-info-image
            program-debug-info-offset
            program-debug-info-addr
            program-debug-info-u32-offset
            program-debug-info-u32-offset-end
            find-program-debug-info

            arity?
            arity-low-pc
            arity-high-pc
            arity-nreq
            arity-nopt
            arity-has-rest?
            arity-allow-other-keys?
            arity-has-keyword-args?
            arity-is-case-lambda?
            arity-arguments-alist
            find-program-arities
            program-minimum-arity

            find-program-docstring

            find-program-properties))

(define-record-type <debug-context>
  (make-debug-context elf base text-base)
  debug-context?
  (elf debug-context-elf)
  (base debug-context-base)
  (text-base debug-context-text-base))

(define (debug-context-image context)
  (elf-bytes (debug-context-elf context)))

(define (u32-offset->addr offset context)
  (+ (debug-context-base context) (* offset 4)))

(define-record-type <program-debug-info>
  (make-program-debug-info context name offset size)
  program-debug-info?
  (context program-debug-info-context)
  (name program-debug-info-name)
  (offset program-debug-info-offset)
  (size program-debug-info-size))

(define (program-debug-info-addr pdi)
  (+ (program-debug-info-offset pdi)
     (debug-context-text-base (program-debug-info-context pdi))
     (debug-context-base (program-debug-info-context pdi))))

(define (program-debug-info-image pdi)
  (debug-context-image (program-debug-info-context pdi)))

(define (program-debug-info-u32-offset pdi)
  ;; OFFSET is in bytes from the beginning of the text section.  TEXT-BASE
  ;; is in bytes from the beginning of the image.  Return OFFSET as a u32
  ;; index from the start of the image.
  (/ (+ (program-debug-info-offset pdi)
        (debug-context-text-base (program-debug-info-context pdi)))
     4))

(define (program-debug-info-u32-offset-end pdi)
  ;; Return the end position as a u32 index from the start of the image.
  (/ (+ (program-debug-info-size pdi)
        (program-debug-info-offset pdi)
        (debug-context-text-base (program-debug-info-context pdi)))
     4))

(define (find-debug-context addr)
  (let* ((bv (find-mapped-elf-image addr))
         (elf (parse-elf bv))
         (base (pointer-address (bytevector->pointer (elf-bytes elf))))
         (text-base (elf-section-offset
                     (or (elf-section-by-name elf ".rtl-text")
                         (error "ELF object has no text section")))))
    (make-debug-context elf base text-base)))

(define (find-elf-symbol elf text-offset)
  (and=>
   (elf-section-by-name elf ".symtab")
   (lambda (symtab)
     (let ((len (elf-symbol-table-len symtab))
           (strtab (elf-section elf (elf-section-link symtab))))
       ;; The symbols should be sorted, but maybe somehow that fails
       ;; (for example if multiple objects are relinked together).  So,
       ;; a modicum of tolerance.
       (define (bisect)
         ;; FIXME: Implement.
         #f)
       (define (linear-search)
         (let lp ((n 0))
           (and (< n len)
                (let ((sym (elf-symbol-table-ref elf symtab n strtab)))
                  (if (and (<= (elf-symbol-value sym) text-offset)
                           (< text-offset (+ (elf-symbol-value sym)
                                             (elf-symbol-size sym))))
                      sym
                      (lp (1+ n)))))))
       (or (bisect) (linear-search))))))

(define* (find-program-debug-info addr #:optional
                                  (context (find-debug-context addr)))
  (cond
   ((find-elf-symbol (debug-context-elf context)
                     (- addr
                        (debug-context-base context)
                        (debug-context-text-base context)))
    => (lambda (sym)
         (make-program-debug-info context
                                  (and=> (elf-symbol-name sym)
                                         ;; The name might be #f if
                                         ;; the string table was
                                         ;; stripped somehow.
                                         (lambda (x)
                                           (and (string? x)
                                                (not (string-null? x))
                                                (string->symbol x))))
                                  (elf-symbol-value sym)
                                  (elf-symbol-size sym))))
   (else #f)))

(define-record-type <arity>
  (make-arity context base header-offset)
  arity?
  (context arity-context)
  (base arity-base)
  (header-offset arity-header-offset))

(define arities-prefix-len 4)
(define arity-header-len (* 6 4))

;;;   struct arity_header {
;;;     uint32_t low_pc;
;;;     uint32_t high_pc;
;;;     uint32_t offset;
;;;     uint32_t flags;
;;;     uint32_t nreq;
;;;     uint32_t nopt;
;;;   }

(define (arity-low-pc* bv header-pos)
  (bytevector-u32-native-ref bv (+ header-pos (* 0 4))))
(define (arity-high-pc* bv header-pos)
  (bytevector-u32-native-ref bv (+ header-pos (* 1 4))))
(define (arity-offset* bv header-pos)
  (bytevector-u32-native-ref bv (+ header-pos (* 2 4))))
(define (arity-flags* bv header-pos)
  (bytevector-u32-native-ref bv (+ header-pos (* 3 4))))
(define (arity-nreq* bv header-pos)
  (bytevector-u32-native-ref bv (+ header-pos (* 4 4))))
(define (arity-nopt* bv header-pos)
  (bytevector-u32-native-ref bv (+ header-pos (* 5 4))))

;;;    #x1: has-rest?
;;;    #x2: allow-other-keys?
;;;    #x4: has-keyword-args?
;;;    #x8: is-case-lambda?

(define (has-rest? flags)         (not (zero? (logand flags (ash 1 0)))))
(define (allow-other-keys? flags) (not (zero? (logand flags (ash 1 1)))))
(define (has-keyword-args? flags) (not (zero? (logand flags (ash 1 2)))))
(define (is-case-lambda? flags)   (not (zero? (logand flags (ash 1 3)))))

(define (arity-nreq arity)
  (arity-nreq* (elf-bytes (debug-context-elf (arity-context arity)))
               (arity-header-offset arity)))

(define (arity-nopt arity)
  (arity-nopt* (elf-bytes (debug-context-elf (arity-context arity)))
               (arity-header-offset arity)))

(define (arity-flags arity)
  (arity-flags* (elf-bytes (debug-context-elf (arity-context arity)))
                (arity-header-offset arity)))

(define (arity-has-rest? arity) (has-rest? (arity-flags arity)))
(define (arity-allow-other-keys? arity) (allow-other-keys? (arity-flags arity)))
(define (arity-has-keyword-args? arity) (has-keyword-args? (arity-flags arity)))
(define (arity-is-case-lambda? arity) (is-case-lambda? (arity-flags arity)))

(define (arity-load-symbol arity)
  (let ((elf (debug-context-elf (arity-context arity))))
    (cond
     ((elf-section-by-name elf ".guile.arities")
      =>
      (lambda (sec)
        (let* ((strtab (elf-section elf (elf-section-link sec)))
               (bv (elf-bytes elf))
               (strtab-offset (elf-section-offset strtab)))
          (lambda (n)
            (string->symbol (string-table-ref bv (+ strtab-offset n)))))))
     (else (error "couldn't find arities section")))))

(define (arity-arguments-alist arity)
  (let* ((bv (elf-bytes (debug-context-elf (arity-context arity))))
         (%load-symbol (arity-load-symbol arity))
         (header (arity-header-offset arity))
         (link-offset (arity-offset* bv header))
         (link (+ (arity-base arity) link-offset))
         (flags (arity-flags* bv header))
         (nreq (arity-nreq* bv header))
         (nopt (arity-nopt* bv header)))
    (define (load-symbol idx)
      (%load-symbol (bytevector-u32-native-ref bv (+ link (* idx 4)))))
    (define (load-symbols skip n)
      (let lp ((n n) (out '()))
        (if (zero? n)
            out
            (lp (1- n)
                (cons (load-symbol (+ skip (1- n))) out)))))
    (define (unpack-scm n)
      (pointer->scm (make-pointer n)))
    (define (load-non-immediate idx)
      (let ((offset (bytevector-u32-native-ref bv (+ link (* idx 4)))))
        (unpack-scm (+ (debug-context-base (arity-context arity)) offset))))
    (and (not (is-case-lambda? flags))
         `((required . ,(load-symbols 0 nreq))
           (optional . ,(load-symbols nreq nopt))
           (rest . ,(and (has-rest? flags) (load-symbol (+ nreq nopt))))
           (keyword . ,(if (has-keyword-args? flags)
                           (load-non-immediate
                            (+ nreq nopt (if (has-rest? flags) 1 0)))
                           '()))
           (allow-other-keys? . ,(allow-other-keys? flags))))))

(define (find-first-arity context base addr)
  (let* ((bv (elf-bytes (debug-context-elf context)))
         (text-offset (- addr
                         (debug-context-text-base context)
                         (debug-context-base context)))
         (headers-start (+ base arities-prefix-len))
         (headers-end (+ base (bytevector-u32-native-ref bv base))))
    ;; FIXME: This is linear search.  Change to binary search.
    (let lp ((pos headers-start))
      (cond
       ((>= pos headers-end) #f)
       ((< text-offset (arity-low-pc* bv pos))
        (lp (+ pos arity-header-len)))
       ((< (arity-high-pc* bv pos) text-offset)
        #f)
       (else
        (make-arity context base pos))))))

(define (read-sub-arities context base outer-header-offset)
  (let* ((bv (elf-bytes (debug-context-elf context)))
         (headers-end (+ base (bytevector-u32-native-ref bv base)))
         (low-pc (arity-low-pc* bv outer-header-offset))
         (high-pc (arity-high-pc* bv outer-header-offset)))
    (let lp ((pos (+ outer-header-offset arity-header-len)) (out '()))
      (if (and (< pos headers-end) (<= (arity-high-pc* bv pos) high-pc))
          (lp (+ pos arity-header-len)
              (cons (make-arity context base pos) out))
          (reverse out)))))

(define* (find-program-arities addr #:optional
                               (context (find-debug-context addr)))
  (and=>
   (elf-section-by-name (debug-context-elf context) ".guile.arities")
   (lambda (sec)
     (let* ((base (elf-section-offset sec))
            (first (find-first-arity context base addr)))
       ;; FIXME: Handle case-lambda arities.
       (cond
        ((not first) '())
        ((arity-is-case-lambda? first)
         (read-sub-arities context base (arity-header-offset first)))
        (else (list first)))))))

(define* (program-minimum-arity addr #:optional
                                (context (find-debug-context addr)))
  (and=>
   (elf-section-by-name (debug-context-elf context) ".guile.arities")
   (lambda (sec)
     (let* ((base (elf-section-offset sec))
            (first (find-first-arity context base addr)))
       (if (arity-is-case-lambda? first)
           (list 0 0 #t) ;; FIXME: be more precise.
           (list (arity-nreq first)
                 (arity-nopt first)
                 (arity-has-rest? first)))))))

(define* (find-program-docstring addr #:optional
                                 (context (find-debug-context addr)))
  (and=>
   (elf-section-by-name (debug-context-elf context) ".guile.docstrs")
   (lambda (sec)
     ;; struct docstr {
     ;;   uint32_t pc;
     ;;   uint32_t str;
     ;; }
     (define docstr-len 8)
     (let* ((start (elf-section-offset sec))
            (end (+ start (elf-section-size sec)))
            (bv (elf-bytes (debug-context-elf context)))
            (text-offset (- addr
                            (debug-context-text-base context)
                            (debug-context-base context))))
       ;; FIXME: This is linear search.  Change to binary search.
       (let lp ((pos start))
         (cond
          ((>= pos end) #f)
          ((< text-offset (bytevector-u32-native-ref bv pos))
           (lp (+ pos docstr-len)))
          ((> text-offset (bytevector-u32-native-ref bv pos))
           #f)
          (else
           (let ((strtab (elf-section (debug-context-elf context)
                                      (elf-section-link sec)))
                 (idx (bytevector-u32-native-ref bv (+ pos 4))))
             (string-table-ref bv (+ (elf-section-offset strtab) idx))))))))))

(define* (find-program-properties addr #:optional
                                  (context (find-debug-context addr)))
  (define (add-name-and-docstring props)
    (define (maybe-acons k v tail)
      (if v (acons k v tail) tail))
    (let ((name (and=> (find-program-debug-info addr context)
                       program-debug-info-name))
          (docstring (find-program-docstring addr context)))
      (maybe-acons 'name name
                   (maybe-acons 'documentation docstring props))))
  (add-name-and-docstring
   (cond
    ((elf-section-by-name (debug-context-elf context) ".guile.procprops")
     => (lambda (sec)
          ;; struct procprop {
          ;;   uint32_t pc;
          ;;   uint32_t offset;
          ;; }
          (define procprop-len 8)
          (let* ((start (elf-section-offset sec))
                 (end (+ start (elf-section-size sec)))
                 (bv (elf-bytes (debug-context-elf context)))
                 (text-offset (- addr
                                 (debug-context-text-base context)
                                 (debug-context-base context))))
            (define (unpack-scm addr)
              (pointer->scm (make-pointer addr)))
            (define (load-non-immediate offset)
              (unpack-scm (+ (debug-context-base context) offset)))
            ;; FIXME: This is linear search.  Change to binary search.
            (let lp ((pos start))
              (cond
               ((>= pos end) '())
               ((< text-offset (bytevector-u32-native-ref bv pos))
                (lp (+ pos procprop-len)))
               ((> text-offset (bytevector-u32-native-ref bv pos))
                '())
               (else
                (load-non-immediate
                 (bytevector-u32-native-ref bv (+ pos 4))))))))))))