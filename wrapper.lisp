#|
 This file is a part of cl-fbx
 (c) 2023 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.fbx)

(defvar *global-pointer-table* (make-hash-table :test 'eql))

(defun global-pointer (ptr)
  (gethash ptr *global-pointer-table*))

(defun (setf global-pointer) (value ptr)
  (if value
      (setf (gethash ptr *global-pointer-table*) value)
      (remhash ptr *global-pointer-table*))
  vlaue)

(defmacro with-ptr-resolve ((value ptr) &body body)
  `(let ((,value (global-pointer ,ptr)))
     (when ,value
       ,@body)))

(defmacro with-ref ((var type) &body body)
  (let ((varg (gensym "VARG"))
        (type (find-symbol (string type) '#:org.shirakumo.fraf.fbx.cffi)))
    `(let ((,varg ,var))
       (macrolet ((f (field)
                    `(,(find-symbol (format NIL "~a-~a" ',type field) (symbol-package ',type)) ,',varg))
                  (p (field)
                    (let ((field (find-symbol (string field) '#:org.shirakumo.fraf.fbx.cffi)))
                      `(cffi:foreign-slot-pointer ,',varg '(:struct ,',type) ',field))))
         ,@body))))

(define-condition fbx-error (error)
  ((handle :initarg :handle :reader handle))
  (:report (lambda (c s) (format s "An FBX error occurred:~%~a"
                                 (message error)))))

(defmethod message ((error fbx-error))
  (cffi:with-foreign-objects ((string :char 2048))
    (fbx:format-error string 2048 (handle error))
    (cffi:foreign-string-to-lisp string)))

(defmethod code ((error fbx-error))
  (fbx:error-type (handle error)))

(defmethod description ((error fbx-error))
  (fbx:description (handle error)))

(defmethod info ((error fbx-error))
  (cffi:foreign-string-to-lisp (cffi:foreign-slot-pointer (handle error) '(:struct fbx:error) 'fbx:info)
                               :count (fbx:error-info-length (handle error))))

(defmethod stack ((error fbx-error))
  (loop for i from 0 below (fbx:error-stack-size (handle error))
        for frame = (cffi:foreign-slot-pointer (handle error) '(:struct fbx:error) 'fbx:stack)
        then (cffi:inc-pointer frame (cffi:foreign-type-size '(:struct fbx:error-frame)))
        collect (list i (fbx:source-line frame) (fbx:function frame) (fbx:description frame))))

(defun check-error (error)
  (unless (eql :none (fbx:error-type error))
    (error 'fbx-error :handle error)))

(defmacro from-args (args field &optional (setter 'setf))
  (let ((val (gensym "VAL")))
    `(let ((,val (getf ,args ,(intern (string field) "KEYWORD") #1='#:no-value)))
       (unless (eq ,val #1#)
         ,(if (eql setter 'setf)
              `(,setter (f ,field) ,val)
              `(,setter (p ,field) ,val))))))

(defun parse-options (opts args)
  (static-vectors:fill-foreign-memory opts (cffi:foreign-type-size '(:struct fbx:load-opts)) 0)
  (with-ref (opts fbx:load-opts)
    (from-args args ignore-geometry)
    (from-args args ignore-animation)
    (from-args args ignore-embedded)
    (from-args args ignore-all-content)
    (from-args args evaluate-skinning)
    (from-args args evaluate-caches)
    (from-args args load-external-files)
    (from-args args ignore-missing-external-files)
    (from-args args skip-skin-vertices)
    (from-args args clean-skin-weights)
    (from-args args disable-quirks)
    (from-args args strict)
    (from-args args allow-unsafe)
    (from-args args index-error-handling)
    (from-args args connect-broken-elements)
    (from-args args allow-nodes-out-of-root)
    (from-args args allow-null-material)
    (from-args args allow-missing-vertex-position)
    (from-args args allow-empty-faces)
    (from-args args generate-missing-normals)
    (from-args args open-main-file-with-default)
    (from-args args path-separator)
    (from-args args file-size-estimate)
    (from-args args read-buffer-size)
    (from-args args progress-interval-hint)
    (from-args args geometry-transform-handling)
    (from-args args space-conversion)
    (from-args args target-unit-meters)
    (from-args args no-prop-unit-scaling)
    (from-args args no-anim-curve-unit-scaling)
    (from-args args normalize-normals)
    (from-args args normalize-tangents)
    (from-args args use-root-transform)
    (from-args args unicode-error-handling)
    (from-args args retain-dom)
    (from-args args file-format)
    (from-args args file-format-lookahead)
    (from-args args no-format-from-content)
    (from-args args no-format-from-extension)
    (from-args args obj-search-mtl-by-filename)
    (from-args args obj-merge-objects)
    (from-args args obj-merge-groups)
    (from-args args obj-split-groups)
    (from-args args geometry-transform-helper-name set-string)
    (from-args args filename set-string)
    (from-args args obj-mtl-data set-blob)
    (from-args args obj-mtl-path set-string)
    (from-args args obj-mtl-data set-blob)
    (from-args args temp-allocator set-allocator)
    (from-args args result-allocator set-allocator)
    (from-args args progress-cb set-callback)
    (from-args args open-file-cb set-callback)
    (from-args args target-axes set-coordinate-axes)
    (from-args args target-camera-axes set-coordinate-axes)
    (from-args args target-light-axes set-coordinate-axes)
    (from-args args root-transform set-transform)))

(defclass fbx-file ()
  ((handle :initarg :handle :initform NIL :accessor handle)
   (source :initarg :source :initform NIL :accessor source)))

(defmethod print-object ((file fbx-file) stream)
  (print-unreadable-object (file stream :type T)
    (format stream "~a" (source file))))

(defmethod free ((file fbx-file))
  (when (handle file)
    (fbx:free-scene (handle file))
    (setf (handle file) NIL)))

(defmethod close ((file fbx-file) &key abort)
  (declare (ignore abort))
  (free file))

(defun parse (source &rest args)
  (cffi:with-foreign-objects ((error '(:struct fbx:error))
                              (opts '(:struct fbx:load-opts)))
    (parse-options opts args)
    (let ((result (apply #'%parse source opts error args)))
      (check-error error)
      result)))

(defgeneric %parse (source opts error &key &allow-other-keys))

(defmethod %parse ((source string) opts error &rest args)
  (make-instance 'fbx-file :handle (fbx:load-file source opts error)))

(defmethod %parse ((source pathname) opts error &key)
  (make-instance 'fbx-file :handle (fbx:load-file (namestring source) opts error)))

(defmethod %parse ((source vector) opts error &rest args &key static-vector-p)
  (check-type source (vector (unsigned-byte 8)))
  (if static-vector-p
      (apply #'%parse (static-vectors:static-vector-pointer source) opts error :data-size (length source) args)
      (let ((ptr (cffi:foreign-alloc :uint8 :count (length source) :initial-contents source)))
        (apply #'%parse ptr opts error :data-size (length source) :deallocate T args))))

(defclass fbx-file-pointer (fbx-file)
  ((deallocate-p :initarg :deallocate-p :accessor deallocate-p)
   (pointer :initarg :pointer :accessor pointer)))

(defmethod close :after ((file fbx-file-pointer) &key abort)
  (declare (ignore abort))
  (when (and (deallocate-p file) (pointer file))
    (cffi:foreign-free (pointer file))
    (setf (pointer file) NIL)))

(defmethod %parse (source opts error &key data-size deallocate)
  (etypecase source
    (cffi:foreign-pointer
     (make-instance 'fbx-file-pointer :handle (fbx:load-memory source data-size opts error)
                                      :deallocate-p deallocate))))

(defclass fbx-file-stream (fbx-file)
  ((stream :initarg :stream :accessor stream)
   (buffer :initarg :buffer :initform (make-array 4096 :element-type '(unsigned-byte 8)) :accessor buffer)
   (stream-struct :initarg :stream-struct :accessor stream-struct)))

(defmethod close :after ((file fbx-file-stream) &key abort)
  (declare (ignore abort))
  (when (stream-struct file)
    (setf (global-pointer (stream-struct file)) NIL)
    (cffi:foreign-free (stream-struct file))
    (setf (stream-struct file) NIL))
  (close (stream file)))

(defmethod %parse ((source stream) opts error &rest args &key prefix)
  (let ((stream (cffi:foreign-alloc '(:struct fbx:stream))))
    (setf (fbx:stream-read-fn stream) (cffi:callback stream-read-cb))
    (setf (fbx:stream-skip-fn stream) (cffi:callback stream-skip-cb))
    (setf (fbx:stream-close-fn stream) (cffi:callback stream-close-cb))
    (setf (fbx:stream-user stream) stream)
    (let ((handle (if prefix
                      (fbx:load-stream-prefix stream prefix opts error)
                      (fbx:load-stream stream opts error))))
      (make-instance 'fbx-file-stream :handle handle :stream source :stream-struct stream))))

(cffi:defcallback stream-read-cb :size ((user :pointer) (data :pointer) (size :size))
  (with-ptr-resolve (file user)
    (let* ((buffer (buffer file))
           (read (read-sequence buffer (stream file) :end (min size (length buffer)))))
      (cffi:with-pointer-to-vector-data (ptr buffer)
        (static-vectors:replace-foreign-memory data ptr read))
      read)))

(cffi:defcallback stream-skip-cb :bool ((user :pointer) (size :size))
  (with-ptr-resolve (file user)
    (etypecase (stream file)
      (file-stream
       (file-position stream (+ (file-position stream) size)))
      (stream
       (let ((buffer (buffer file)))
         (loop until (<= size 0)
               for read = (read-sequence buffer (stream file) :end (min (length buffer) size))
               do (decf size read))
         T)))))

(cffi:defcallback stream-close-cb :void ((user :pointer))
  (with-ptr-resolve (file user)
    (close file)))

(cffi:defcallback progress-cb fbx:progress-result ((user :pointer) (progress :pointer))
  (with-ptr-resolve (fun user)
    (funcall fun (fbx:progress-bytes-read progress) (fbx:progress-bytes-total progress))))

(cffi:defcallback open-file-cb :bool ((user :pointer) (stream :pointer) (path :string) (length :size) (info :pointer))
  (with-ptr-resolve (fun user)
    (funcall fun stream path (fbx:open-file-info-type info)
             (cffi:foreign-slot-pointer info '(:struct fbx:open-file-info) 'fbx:temp-allocator))))

(cffi:defcallback close-memory-cb :void ((user :pointer) (data :pointer) (size :size))
  (with-ptr-resolve (fun user)
    (funcall fun data size)))

(cffi:defcallback alloc-cb :pointer ((user :pointer) (size :size))
  (with-ptr-resolve (allocator user)
    (allocate allocator size)))

(cffi:defcallback realloc-cb :pointer ((user :pointer) (old-ptr :pointer) (old-size :size) (new-size :size))
  (with-ptr-resolve (allocator user)
    (reallocate allocator old-ptr old-size new-size)))

(cffi:defcallback free-cb :void ((user :pointer) (ptr :pointer) (size :size))
  (with-ptr-resolve (allocator user)
    (deallocate allocator ptr size)))

(cffi:defcallback free-allocator-cb :void ((user :pointer))
  (with-ptr-resolve (allocator user)
    (free allocator)))
