(in-package :cl-user)

(defpackage #:6502-cpu
  (:nicknames #:cpu)
  (:use :cl :cl-user)
  (:export #:make-cpu #:pages-differ #:reset #:power-on #:pull-stack
           #:push-stack #:pull16 #:push16 #:cpu-cycles #:cpu-accumulator #:cpu-x
           #:cpu-y #:cpu-pc #:cpu-sp #:cpu-memory #:step-pc #:fetch #:wrap-word
           #:wrap-byte))

(in-package :6502-cpu)

(defstruct flags
  "Flag register"
  (carry nil)
  (zero nil)
  (interrupt nil)
  (bcd nil)
  (soft-interrupt nil)
  (unused T)
  (overflow nil)
  (negative nil))

(defstruct cpu
  "A model 6502"
  (cycles 0 :type (unsigned-byte 16))
  (accumulator 0 :type (unsigned-byte 8))
  (x 0 :type (unsigned-byte 8))
  (y 0 :type (unsigned-byte 8))
  (pc 0 :type (unsigned-byte 16))
  (sp 0 :type (unsigned-byte 8))
  (sr (make-flags))
  (memory (make-array #x800 :element-type '(unsigned-byte 8))))

(defstruct instruction
  "6502 instruction"
  (unmasked-opcode 0 :type (unsigned-byte 8))
  (opcode 0 :type (unsigned-byte 8))
  (hi-byte 0 :type (unsigned-byte 8))
  (lo-byte 0 :type (unsigned-byte 8))
  (addressing-mode :implicit))

(defun wrap-byte (val)
  (logand #xFF val))

(defun wrap-word (val)
  (logand #xFFFF val))

(defun pages-differ (a b)
  (declare ((unsigned-byte 16) a b))
  (not
   (=
    (logand a #xFF00)
    (logand b #xFF00))))

(defun read-cpu (c addr)
  (declare (ignore c addr))
  0)

(defun reset (c)
  "Reset state of cpu"
  (setf (cpu-sp c) (wrap-byte (- (cpu-sp c) 3)))
  (setf (flags-interrupt (cpu-sr c)) T))

(defun power-on (c)
  "Power on state of cpu"
  (setf
   (cpu-sr c)
   (make-flags
    :carry nil
    :zero nil
    :interrupt T
    :bcd nil
    :soft-interrupt T
    :unused T
    :overflow nil
    :negative nil))
  (setf (cpu-sp c) #xFD))

(defun pull-stack (c)
  "Empty stack pull"
  (setf (cpu-sp c) (wrap-byte (1+ (cpu-sp c))))
  (aref (cpu-memory c) (logior (cpu-sp c) #x100)))

(defun push-stack (c val)
  "Put a value on the stack and then push it forwards"
  (declare ((unsigned-byte 8) val))
  (setf
   (aref
    (cpu-memory c)
    (logior (cpu-sp c) #x100))
   val)
  (setf
   (cpu-sp c)
   (wrap-byte (1- (cpu-sp c)))))

(defun pull16 (c)
  "Pull twice and make a 16 bit address."
  (logior (pull-stack c) (ash (pull-stack c) 8)))

(defun push16 (c val)
  "Push twice."
  (push-stack c (wrap-byte (ash val -8)))
  (push-stack c (wrap-byte val)))

(defun step-pc (c mode)
  "Step the pc according to the addressing mode."
  (setf
   (cpu-pc c)
   (wrap-word
    (+
     (cpu-pc c)
     (cond
       ((equal mode :implicit) 1)
       ((equal mode :accumulator) 1)
       ((equal mode :immediate) 2)
       ((equal mode :zero-page) 2)
       ((equal mode :absolute) 3)
       ((equal mode :relative) 2)
       ((equal mode :indirect) 3)
       ((equal mode :zero-page-indexed-x) 2)
       ((equal mode :zero-page-indexed-y) 2)
       ((equal mode :absolute-indexed-x) 3)
       ((equal mode :absolute-indexed-y) 3)
       ((equal mode :indexed-indirect) 2)
       ((equal mode :indirect-indexed) 2)
       (T 1)))))) ;Silence warnings with this last line

(defun set-zn (c val)
  "Sets the zero or negative flag"
  ;If zero, set the bit
  (setf
   (flags-zero (cpu-sr c))
   (if (= val 0)
     T
     nil))
  ;If the MSB is set, it's negative.
  (setf
   (flags-negative (cpu-sr c))
   (if (ldb (byte 1 7) val)
     T
     nil)))

(defun get-address (c inst)
  (let ((mode (instruction-addressing-mode inst)))
    (cond
      ((equal mode :zero-page)
       (instruction-lo-byte inst))
      ((equal mode :absolute)
       (wrap-word
        (logior
         (ash (instruction-hi-byte inst) 8)
         (instruction-lo-byte inst))))
      ((equal mode :relative)
       (wrap-word
        (+
         (cpu-pc c)
         (if (= (ldb (byte 7 1) (instruction-lo-byte inst)) 1)
           (*
            -1
            (logand #x7f (instruction-lo-byte inst)))
           (logand #x7f (instruction-lo-byte inst))))))
      ((equal mode :indirect)
       (let ((ptr-addr
              (wrap-word
               (logior
                (ash (instruction-lo-byte inst) 8)
                (instruction-hi-byte inst)))))
         (wrap-word
          (logior
           (ash
            (read-cpu
             c
             (wrap-word (1+ ptr-addr)))
            8)
           (read-cpu c ptr-addr)))))
      ((equal mode :zero-page-indexed-x)
       (wrap-byte (+ (instruction-lo-byte inst) (cpu-x c))))
      ((equal mode :zero-page-indexed-y)
       (wrap-byte (+ (instruction-lo-byte inst) (cpu-y c))))
      ((equal mode :absolute-indexed-x)
       (wrap-word
        (+
         (logior
          (ash (instruction-hi-byte inst) 8)
          (instruction-lo-byte inst))
         (cpu-x c))))
      ((equal mode :absolute-indexed-y)
       (wrap-word
        (+
         (logior
          (ash (instruction-hi-byte inst) 8)
          (instruction-lo-byte inst))
         (cpu-y c))))
      ((equal mode :indexed-indirect)
       (read-cpu
        c
        (wrap-byte
         (+
          (instruction-lo-byte inst)
          (cpu-x c)))))
      ((equal mode :indirect-indexed)
       (wrap-byte
        (+
         (read-cpu
          c
          (instruction-lo-byte inst))
         (cpu-y c))))
      (T 1))))

(defun fetch (c)
  "Fetch the next instruction from memory"
  (make-instruction
   :unmasked-opcode (aref (cpu-memory c) (cpu-pc c))
   :lo-byte (aref (cpu-memory c) (wrap-word (+ (cpu-pc c) 1)))
   :hi-byte (aref (cpu-memory c) (wrap-word (+ (cpu-pc c) 2)))))

(defun decode (opcode)
  "Decodes the opcode."
  opcode)