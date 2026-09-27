;;;; src/value.lisp
;;;;
;;;; Conversion between caller values and the form kept in the store.
;;;;
;;;; bknr.datastore's transaction log writes integers, ratios, floats,
;;;; characters, symbols, strings, lists, arrays, hash tables and
;;;; persistent store objects, and nothing else. STORED-FORM turns a
;;;; caller value into a fresh tree of those types:
;;;;
;;;;   - an instance of a named standard class or structure becomes
;;;;     (%INSTANCE class-name (slot-name . form) ...), bound slots only;
;;;;   - a hash table becomes (%HASH-TABLE test (key-form . value-form) ...)
;;;;     with entries ordered by printed key, so equal tables hash alike;
;;;;   - strings, lists and arrays are copied element by element;
;;;;   - a persistent store object is kept as a reference.
;;;;
;;;; VALUE-FROM-FORM rebuilds a fresh value from a stored form. Neither
;;;; function returns structure shared with its argument, so changing a
;;;; value after storing it, or after reading it back, leaves the store
;;;; unchanged.

(in-package :bknr.hashkv)

(define-condition unstorable-value-error (error)
  ((value :initarg :value :reader unstorable-value-error-value)
   (reason :initarg :reason :reader unstorable-value-error-reason))
  (:report (lambda (condition stream)
             (let ((*print-circle* t) (*print-length* 5) (*print-level* 3))
               (format stream "~S cannot be stored: ~A."
                       (unstorable-value-error-value condition)
                       (unstorable-value-error-reason condition)))))
  (:documentation "Signalled by PUT-VALUE, PUT-KEYED, BATCH-PUT and ENQUEUE
when the value, or something inside it, cannot be written to the
transaction log, or when the value contains itself."))

(defun unstorable (value reason)
  "Signals UNSTORABLE-VALUE-ERROR for VALUE with REASON."
  (error 'unstorable-value-error :value value :reason reason))

(defun call-with-ancestor (object ancestors function)
  "Calls FUNCTION with OBJECT recorded in the EQ table ANCESTORS, which holds
the objects enclosing the one being converted. Signals
UNSTORABLE-VALUE-ERROR when OBJECT is already there, since the value then
contains itself."
  (when (gethash object ancestors)
    (unstorable object "the value contains itself"))
  (setf (gethash object ancestors) t)
  (unwind-protect (funcall function)
    (remhash object ancestors)))

(defun named-class-p (class)
  "True when CLASS has a name under which FIND-CLASS returns CLASS itself."
  (let ((name (class-name class)))
    (and name (eq class (find-class name nil)))))

(defun instance-form (instance ancestors)
  "Returns the %INSTANCE form of INSTANCE, a standard or structure object."
  (let ((class (class-of instance)))
    (unless (named-class-p class)
      (unstorable instance "its class has no global name"))
    (call-with-ancestor
     instance ancestors
     (lambda ()
       (list* '%instance (class-name class)
              (loop for slot in (closer-mop:class-slots class)
                    for name = (closer-mop:slot-definition-name slot)
                    when (and (eq :instance (closer-mop:slot-definition-allocation slot))
                              (slot-boundp instance name))
                      collect (cons name (form-of (slot-value instance name) ancestors))))))))

(defun printed-key (form)
  "Returns FORM printed under standard syntax without requiring readability,
for ordering hash table entries."
  (with-standard-io-syntax
    (let ((*print-readably* nil))
      (prin1-to-string form))))

(defun hash-table-form (table ancestors)
  "Returns the %HASH-TABLE form of TABLE, entries ordered by printed key."
  (call-with-ancestor
   table ancestors
   (lambda ()
     (let ((entries '()))
       (maphash (lambda (key value)
                  (push (cons (form-of key ancestors) (form-of value ancestors)) entries))
                table)
       (list* '%hash-table (hash-table-test table)
              (sort entries #'string< :key (lambda (entry) (printed-key (car entry)))))))))

(defun array-form (array ancestors)
  "Returns a copy of ARRAY with the same dimensions and element type and
each element converted."
  (call-with-ancestor
   array ancestors
   (lambda ()
     (let ((copy (make-array (array-dimensions array) :element-type (array-element-type array))))
       (dotimes (index (array-total-size array) copy)
         (setf (row-major-aref copy index) (form-of (row-major-aref array index) ancestors)))))))

(defun list-form (list ancestors)
  "Returns a copy of LIST, including a dotted tail, with each element
converted. Each cons of the spine stays in ANCESTORS while the elements
are converted, so an element that refers back to the list is caught."
  (let ((marked '()))
    (unwind-protect
         (loop for tail = list then (cdr tail)
               while (consp tail)
               do (when (gethash tail ancestors)
                    (unstorable list "the value contains itself"))
                  (setf (gethash tail ancestors) t)
                  (push tail marked)
               collect (form-of (car tail) ancestors) into elements
               finally (return (nconc elements (form-of tail ancestors))))
      (dolist (cons marked)
        (remhash cons ancestors)))))

(defun form-of (value ancestors)
  "Returns the stored form of VALUE. ANCESTORS holds the enclosing objects."
  (typecase value
    ((or rational float character symbol) value)
    (bknr.datastore:store-object value)
    (string (copy-seq value))
    (cons (list-form value ancestors))
    ((or function stream package pathname readtable random-state condition)
     (unstorable value (format nil "a ~(~A~) cannot be written to the transaction log"
                               (type-of value))))
    (number (unstorable value "only rational and floating point numbers can be stored"))
    (hash-table (hash-table-form value ancestors))
    (array (array-form value ancestors))
    ((or standard-object structure-object) (instance-form value ancestors))
    (t (unstorable value "bknr.datastore cannot write objects of this type"))))

(defun stored-form (value)
  "Returns the form under which VALUE is stored: a fresh tree of types the
transaction log can write. Signals UNSTORABLE-VALUE-ERROR for values
that cannot be stored or that contain themselves."
  (form-of value (make-hash-table :test 'eq)))

(defun instance-from-form (form)
  "Rebuilds an instance from an %INSTANCE form without calling
INITIALIZE-INSTANCE, as bknr.datastore does when it restores objects.
Slots the class no longer has are skipped."
  (destructuring-bind (class-name &rest slots) (rest form)
    (let ((instance (allocate-instance (find-class class-name))))
      (loop for (name . slot-form) in slots
            when (slot-exists-p instance name)
              do (setf (slot-value instance name) (value-from-form slot-form)))
      instance)))

(defun hash-table-from-form (form)
  "Rebuilds a hash table from a %HASH-TABLE form."
  (destructuring-bind (test &rest entries) (rest form)
    (let ((table (make-hash-table :test test)))
      (loop for (key . value) in entries
            do (setf (gethash (value-from-form key) table) (value-from-form value)))
      table)))

(defun list-from-form (list)
  "Rebuilds a list, including a dotted tail, from its stored form."
  (loop for tail = list then (cdr tail)
        while (consp tail)
        collect (value-from-form (car tail)) into elements
        finally (return (nconc elements (value-from-form tail)))))

(defun array-from-form (array)
  "Rebuilds an array from its stored form."
  (let ((copy (make-array (array-dimensions array) :element-type (array-element-type array))))
    (dotimes (index (array-total-size array) copy)
      (setf (row-major-aref copy index) (value-from-form (row-major-aref array index))))))

(defun raw-hash-table-copy (table)
  "Copies TABLE, a hash table stored raw by version 1.0.0, rebuilding its
keys and values."
  (let ((copy (make-hash-table :test (hash-table-test table))))
    (maphash (lambda (key value)
               (setf (gethash (value-from-form key) copy) (value-from-form value)))
             table)
    copy))

(defun value-from-form (form)
  "Returns a fresh value rebuilt from FORM. Persistent store objects are
returned as the same object. Forms written by version 1.0.0, which stored
values unconverted, are copied."
  (typecase form
    (cons (case (car form)
            (%instance (instance-from-form form))
            (%hash-table (hash-table-from-form form))
            (t (list-from-form form))))
    (string (copy-seq form))
    (hash-table (raw-hash-table-copy form))
    (array (array-from-form form))
    (t form)))
