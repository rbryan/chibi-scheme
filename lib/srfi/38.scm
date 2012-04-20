;;;; srfi-38.scm - reading and writing shared structures
;;
;; This code was written by Alex Shinn in 2009 and placed in the
;; Public Domain.  All warranties are disclaimed.

(define (extract-shared-objects x)
  (let ((seen '()))
    (let find ((x x))
      (cond
       ((assq x seen)
        => (lambda (cell) (set-cdr! cell (+ (cdr cell) 1))))
       ((pair? x)
        (set! seen (cons (cons x 1) seen))
        (find (car x))
        (find (cdr x)))
       ((vector? x)
        (set! seen (cons (cons x 1) seen))
        (do ((i 0 (+ i 1)))
            ((= i (vector-length x)))
          (find (vector-ref x i))))
       (else
        (let ((type (type-of x)))
          (cond
           ((and type (type-printer type))
            (set! seen (cons (cons x 1) seen))
            (let ((num-slots (type-num-slots type)))
              (let lp ((i 0))
                (cond
                 ((< i num-slots)
                  (find (slot-ref type x i))
                  (lp (+ i 1))))))))))))
    (let extract ((ls seen) (res '()))
      (cond
       ((null? ls) res)
       ((> (cdar ls) 1) (extract (cdr ls) (cons (cons (caar ls) #f) res)))
       (else (extract (cdr ls) res))))))

(define (write-with-shared-structure x . o)
  (let ((out (if (pair? o) (car o) (current-output-port)))
        (shared (extract-shared-objects x))
        (count 0))
    (define (check-shared x prefix cont)
      (let ((cell (assq x shared)))
        (cond ((and cell (cdr cell))
               (display prefix out)
               (display "#" out)
               (write (cdr cell) out)
               (display "#" out))
              (else
               (cond (cell
                      (display prefix out)
                      (display "#" out)
                      (write count out)
                      (display "=" out)
                      (set-cdr! cell count)
                      (set! count (+ count 1))))
               (cont x cell)))))
    (cond
     ((null? shared)
      (write x out))
     (else
      (let wr ((x x))
        (check-shared
         x
         ""
         (lambda (x shared?)
           (cond
            ((pair? x)
             (display "(" out)
             (wr (car x))
             (let lp ((ls (cdr x)))
               (check-shared
                ls
                " . "
                (lambda (ls shared?)
                  (cond ((null? ls))
                        ((pair? ls)
                         (cond
                          (shared?
                           (display "(" out)
                           (wr (car ls))
                           (check-shared
                            (cdr ls)
                            " . "
                            (lambda (ls shared?) (lp ls)))
                           (display ")" out))
                          (else
                           (display " " out)
                           (wr (car ls))
                           (lp (cdr ls)))))
                        (else
                         (display " . " out)
                         (wr ls))))))
             (display ")" out))
            ((vector? x)
             (display "#(" out)
             (let ((len (vector-length x)))
               (cond ((> len 0)
                      (wr (vector-ref x 0))
                      (do ((i 1 (+ i 1)))
                          ((= i len))
                        (display " " out)
                        (wr (vector-ref x i))))))
             (display ")" out))
            ((let ((type (type-of x)))
               (and (type? type) (type-printer type)))
             => (lambda (printer) (printer x wr out)))
            (else
             (write x out))))))))))

(define write/ss write-with-shared-structure)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (skip-line in)
  (let ((c (read-char in)))
    (if (not (or (eof-object? c) (eqv? c #\newline)))
        (skip-line in))))

(define (skip-whitespace in)
  (case (peek-char in)
    ((#\space #\tab #\newline #\return)
     (read-char in)
     (skip-whitespace in))
    ((#\;)
     (skip-line in)
     (skip-whitespace in))))

(define (skip-comment in depth)
  (case (read-char in)
    ((#\#) (skip-comment in (if (eqv? #\| (peek-char in)) (+ depth 1) depth)))
    ((#\|) (if (eqv? #\# (peek-char in))
               (if (zero? depth) (read-char in) (skip-comment in (- depth 1)))
               (skip-comment in depth)))
    (else (if (eof-object? (peek-char in))
              (error "unterminated #| comment")
              (skip-comment in depth)))))

(define delimiters
  '(#\; #\( #\) #\{ #\} #\space #\tab #\newline #\return))

(define named-chars
  `(("newline" . #\newline)
    ("return" . #\return)
    ("space" . #\space)
    ("tab" . #\tab)
    ("null" . ,(integer->char 0))
    ("alarm" . ,(integer->char 7))
    ("backspace" . ,(integer->char 8))
    ("escape" . ,(integer->char 27))
    ("delete" . ,(integer->char 127))))

(define read-with-shared-structure
  (let ((read read))
    (lambda o
      (let ((in (if (pair? o) (car o) (current-input-port)))
            (shared '()))
        (define (read-label res)
          (let ((c (peek-char in)))
            (if (and (not (eof-object? c))
                     (or (char-numeric? c)
                         (memv (char-downcase c) '(#\a #\b #\c #\d #\e #\f))))
              (read-label (cons (read-char in) res))
              (list->string (reverse res)))))
        (define (read-number base)
          (let* ((str (read-label '()))
                 (n (string->number str base))
                 (c (peek-char in)))
            (if (or (not n) (not (or (eof-object? c) (memv c delimiters))))
                (error "read error: invalid number syntax" str c)
                n)))
        (define (read-float-tail in) ;; called only after a leading period
          (let lp ((res 0.0) (k 0.1))
            (let ((c (peek-char in)))
              (cond
               ((char-numeric? c)
                (lp (+ res (* (digit-value (read-char in)) k)) (* k 0.1)))
               ((or (eof-object? c) (memv c delimiters)) res)
               (else (error "invalid char in float syntax" c))))))
        (define (read-name c in)
          (let lp ((ls (if (char? c) (list c) '())))
            (let ((c (peek-char in)))
              (cond ((or (eof-object? c) (memv c delimiters))
                     (list->string (reverse ls)))
                    (else (lp (cons (read-char in) ls)))))))
        (define (read-named-char c in)
          (let ((name (read-name c in)))
            (cond ((assoc name named-chars string-ci=?) => cdr)
                  (else (error "unknown char name" name)))))
        (define (read-type-id in)
          (let ((ch (peek-char in)))
            (cond
             ((eqv? ch #\#)
              (read-char in)
              (let ((id (read in)))
                (cond ((eq? id 't) #t)
                      ((integer? id) id)
                      (else (error "invalid type identifier" id)))))
             ((eqv? ch #\")
              (read in))
             (else
              (error "invalid type identifier syntax" ch)))))
        (define (read-object)
          (let ((name (read-name #f in)))
            (skip-whitespace in)
            (let* ((id (read-type-id in))
                   (type (lookup-type name id)))
              (let lp ((ls '()))
                (skip-whitespace in)
                (cond
                 ((eof-object? (peek-char in))
                  (error "missing closing }"))
                 ((eqv? #\} (peek-char in))
                  (read-char in)
                  (let ((res ((make-constructor #f type))))
                    (let lp ((ls (reverse ls)) ( i 0))
                      (cond
                       ((null? ls)
                        res)
                       (else
                        (slot-set! type res i (car ls))
                        (lp (cdr ls) (+ i 1)))))))
                 (else (lp (cons (read-one) ls))))))))
        (define (read-one)
          (skip-whitespace in)
          (case (peek-char in)
            ((#\#)
             (read-char in)
             (if (eof-object? (peek-char in))
                 (error "read error: incomplete # found at end of input"))
             (case (char-downcase (peek-char in))
               ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9)
                (let* ((str (read-label '()))
                       (n (string->number str)))
                  (if (not n) (error "read error: invalid reference" str))
                  (cond
                   ((eqv? #\= (peek-char in))
                    (read-char in)
                    (let* ((cell (list #f))
                           (thunk (lambda () (car cell))))
                      (set! shared (cons (cons n thunk) shared))
                      (let ((x (read-one)))
                        (set-car! cell x)
                        x)))
                   ((eqv? #\# (peek-char in))
                    (read-char in)
                    (cond ((assv n shared) => cdr)
                          (else (error "read error: unknown reference" n))))
                   (else
                    (error "read error: expected # after #n" (read-char in))))))
               ((#\;)
                (read-char in)
                (read-one) ;; discard
                (read-one))
               ((#\|)
                (skip-comment in 0))
               ((#\!)
                (let ((name (read-name #f in)))
                  (cond
                   ((string-ci=? name "!fold-case")
                    (set-port-fold-case! in #t))
                   ((string-ci=? name "!no-fold-case")
                    (set-port-fold-case! in #f))
                   (else ;; assume a #!/bin/bash line
                    (skip-line in)))
                  (let ((res (read-one)))
                    (if (not (eof-object? res))
                        res))))
               ((#\() (list->vector (read-one)))
               ((#\') (read-char in) (list 'syntax (read-one)))
               ((#\`) (read-char in) (list 'quasisyntax (read-one)))
               ((#\t) (let ((s (read-name #f in)))
                        (or (string-ci=? s "t") (string-ci=? s "true")
                            (error "bad # syntax" s))))
               ((#\f) (let ((s (read-name #f in)))
                        (if (or (string-ci=? s "f") (string-ci=? s "false"))
                            #f
                            (error "bad # syntax" s))))
               ((#\d) (read-char in) (read in))
               ((#\x) (read-char in) (read-number 16))
               ((#\o) (read-char in) (read-number 8))
               ((#\b) (read-char in) (read-number 2))
               ((#\i) (read-char in) (exact->inexact (read-one)))
               ((#\e) (read-char in) (inexact->exact (read-one)))
               ((#\\)
                (read-char in)
                (let* ((c1 (read-char in))
                       (c2 (peek-char in)))
                  (if (or (eof-object? c2) (memv c2 delimiters))
                      c1
                      (read-named-char c1 in))))
               (else
                (error "unknown # syntax: " (peek-char in)))))
            ((#\()
             (read-char in)
             (let lp ((res '()))
               (skip-whitespace in)
               (let ((c (peek-char in)))
                 (case c
                   ((#\))
                    (read-char in)
                    (reverse res))
                   ((#\.)
                    (read-char in)
                    (cond
                     ((memv (peek-char in) delimiters)
                      (let ((tail (read-one)))
                        (skip-whitespace in)
                        (if (eqv? #\) (peek-char in))
                            (begin (read-char in) (append (reverse res) tail))
                            (error "expected end of list after dot"))))
                     ((char-numeric? (peek-char in))
                      (lp (cons (read-float-tail in) res)))
                     (else (string->symbol (read-name #\. in)))))
                   (else
                    (if (eof-object? c)
                        (error "unterminated list")
                        (lp (cons (read-one) res))))))))
            ((#\{)
             (read-char in)
             (read-object))
            ((#\') (read-char in) (list 'quote (read-one)))
            ((#\`) (read-char in) (list 'quasiquote (read-one)))
            ((#\,)
             (read-char in)
             (list (if (eqv? #\@ (peek-char in))
                       (begin (read-char in) 'unquote-splicing)
                       'unquote)
                   (read-one)))
            (else
             (read in))))
        ;; body
        (let ((res (read-one)))
          (if (pair? shared)
              (patch res))
          res)))))

(define (hole? x) (procedure? x))
(define (fill-hole x) (if (hole? x) (fill-hole (x)) x))

(define (patch x)
  (cond
   ((pair? x)
    (if (hole? (car x)) (set-car! x (fill-hole (car x))) (patch (car x)))
    (if (hole? (cdr x)) (set-cdr! x (fill-hole (cdr x))) (patch (cdr x))))
   ((vector? x)
    (do ((i (- (vector-length x) 1) (- i 1)))
        ((< i 0))
      (let ((elt (vector-ref x i)))
        (if (hole? elt)
            (vector-set! x i (fill-hole elt))
            (patch elt)))))
   (else
    (let* ((type (type-of x))
           (slots (and type (type-slots type))))
      (cond
       (slots
        (let lp ((i 0) (ls slots))
          (cond
           ((pair? ls)
            (let ((elt (slot-ref type x i)))
              (if (hole? elt)
                  (slot-set! type x i (fill-hole elt))
                  (patch elt))
              (lp (+ i 1) (cdr ls))))))))))))

(define read/ss read-with-shared-structure)
