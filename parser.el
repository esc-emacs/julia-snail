;;; parser.el --- Julia Snail parser -*- lexical-binding: t -*-


;;; --- requirements

(require 'dash)
(require 'parsec)
(require 'julia-mode)
(require 'rx)


;;; --- helpers

(defmacro julia-snail-parser--parsec-query (parser &optional placeholder)
  "Similar to parsec-query, but always returns the point position
at which the parser started matching. If placeholder is given,
replace the result of the parser with it."
  (let ((start (gensym))
        (res (gensym))
        (ph (gensym)))
    `(let ((,start (point))
           (,res ,parser)
           (,ph ,placeholder))
       (list (if ,ph ,ph ,res)
             ,start))))


;;; --- parser rules (flagged with *)

(defun julia-snail-parser--*whitespace ()
  (parsec-many-as-string
   (parsec-re "[[:space:]\r\n]")))

(defun julia-snail-parser--*identifier ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-re "[._[:alnum:]]+")))

(defmacro julia-snail-parser--*keyword (kw)
  `(parsec-and
    (julia-snail-parser--*whitespace)
    (parsec-return
        (let ((case-fold-search nil))
          (parsec-str ,kw))
      (parsec-lookahead (parsec-re "[^[:alnum:]_]")))))

(defun julia-snail-parser--*string-tq ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-query (parsec-re "\"\"\"\\(\\(?:.\\|\n\\)*?\\)\"\"\"") :group 1)))

(defun julia-snail-parser--*string-dq ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-query (parsec-re
                  (rx "\"" (group-n 1 (*? (or "\\\"" anything))) "\""))
                 :group 1)))

(defun julia-snail-parser--*string-non-standard-literal ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-query (parsec-re
                  (rx (1+ alpha) ; non-standard literal indication
                      "\"" (group-n 1 (*? (or "\\\"" anything))) "\"" ; string
                      (*? alpha) ; flags
                      ))
                 :group 1)))

(defun julia-snail-parser--*string ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-or (julia-snail-parser--*string-tq)
              (julia-snail-parser--*string-dq)
              (julia-snail-parser--*string-non-standard-literal))))

(defun julia-snail-parser--*comment ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-re "#.*?$")))

(defun julia-snail-parser--*comment-multiline ()
  ;; use this as an example of the parsec-many parsec-try combination
  (parsec-many
   (parsec-try
    (parsec-and
     (julia-snail-parser--*whitespace)
     (parsec-re "#.*?$")))))

(defun julia-snail-parser--*brackets ()
  (parsec-and
   (parsec-collect-as-string
    ;;"B" ; put this back to debug bracket expression parsing
    (parsec-str "[")
    (parsec-many-as-string
     (parsec-or
      (parsec-re (rx (not (any "[" "]"))))
      (julia-snail-parser--*brackets)))
    (parsec-str "]"))))

(defun julia-snail-parser--*end ()
  (if (looking-at (rx (* (or blank "\n")) "#"))
      (parsec-stop :expected "end"
                   :found (parsec-eof-or-char-as-string))
    (parsec-and
     (julia-snail-parser--*whitespace)
     (parsec-re (rx (* (or blank "\n" (syntax punctuation)))))
     (julia-snail-parser--parsec-query
      (parsec-re "end")
      :end))))

(defun julia-snail-parser--parsec-re-group (regexp group)
  "Parse the input matching the regular expression REGEXP, but
extract only GROUP (numbered as per MATCH-STRING."
  (if (looking-at regexp)
      (progn (goto-char (match-end group))
             (match-string group))
    (parsec-stop :expected regexp
                 :found (parsec-eof-or-char-as-string))))

;; A brief explanation of the code leading to julia-snail-parser--*other. Since
;; this parser is really here just to detect blocks in Julia code, it needs to
;; consume code which does not look like strings, comments, brackets, and
;; keywords which start and end blocks. This detection is done with some really
;; nasty regex hacks. julia-snail-parser--*other checks to see if it's about to
;; read an "other" element (anything except a comment, string, bracket, or
;; block). If it is, it uses a regex to consume everything up to an element it
;; thinks is "non-other".
;;
;; Needless to say, this is tricky and full of edge and corner cases. In
;; particular, Julia's use of "end" as a syntactic marker to indicate "end of
;; array" considerably complicates matters.
;;
;; Another fun problem has to do with consuming whitespace and properly
;; demarcating keywords, so the identifier "append" does not get parsed as "app"
;; and the keyword "end".
;;
;; Why this horrid implementation:
;; - Because writing a real Julia parser is way too hard. No specifications.
;; - Because I tried to use Parsec primitives to build this, and it was unusably
;;   slow.

(defconst julia-snail-parser--rx-other-markers
  '(or "#" "\"" "[" "]"))

(defconst julia-snail-parser--rx-other-keywords
  '(or "end"
       "module" "baremodule"
       "function" "macro"
       "abstract type" "primitive type"
       "struct" "mutable struct"
       "if" "while" "for" "begin" "quote" "try" "let"))

(defconst julia-snail-parser--rx-other-marker-or-keyword
  (rx-to-string
   `(or ,julia-snail-parser--rx-other-markers
        (and (+ (or line-start blank "\n" "\r"))
             ,julia-snail-parser--rx-other-keywords
             (or line-end blank
                 (syntax punctuation)
                 (syntax open-parenthesis)
                 (syntax close-parenthesis))))))

(defconst julia-snail-parser--rx-other-consume-to-marker
  (rx-to-string
   `(and (group-n 1 (*? anything))
         (group-n 2 ,julia-snail-parser--rx-other-markers))))

(defconst julia-snail-parser--rx-other-consume-to-keyword
  (rx-to-string
   `(and (group-n 1 (*? anything)
                  (+ (or line-start blank "\n" "\r"
                         (syntax open-parenthesis)
                         (syntax close-parenthesis))))
         (group-n 2 (and ,julia-snail-parser--rx-other-keywords
                         (or line-end blank
                             (syntax punctuation)
                             (syntax open-parenthesis)
                             (syntax close-parenthesis)))))))

(defun julia-snail-parser--*other ()
  (with-syntax-table julia-mode-syntax-table
    (if (looking-at julia-snail-parser--rx-other-marker-or-keyword)
        (parsec-stop :expected "'other' syntax"
                     :found (parsec-eof-or-char-as-string))
      (let ((match-csb (when (looking-at julia-snail-parser--rx-other-consume-to-marker)
                         (match-beginning 2)))
            (match-kw (when (looking-at julia-snail-parser--rx-other-consume-to-keyword)
                        (match-beginning 2))))
        (cond ((and match-csb (or (not match-kw) (< match-csb match-kw)))
               (julia-snail-parser--parsec-re-group julia-snail-parser--rx-other-consume-to-marker 1))
              ((and match-kw (or (not match-csb) (>= match-csb match-kw)))
               (julia-snail-parser--parsec-re-group julia-snail-parser--rx-other-consume-to-keyword 1))
              (t (parsec-re (rx (* anything)))))))))

(defun julia-snail-parser--*expression ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-or (julia-snail-parser--*comment)
              (julia-snail-parser--*string)
              (julia-snail-parser--*brackets)
              (julia-snail-parser--*block)
              (julia-snail-parser--*other))))

(defun julia-snail-parser--*start-module ()
  (-snoc
   (julia-snail-parser--parsec-query (parsec-or
                                      (julia-snail-parser--*keyword "module")
                                      (julia-snail-parser--*keyword "baremodule"))
                                     :module)
   (julia-snail-parser--*identifier)))

(defun julia-snail-parser--*start-function ()
  (-snoc
   (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "function") :function)
   (parsec-optional (julia-snail-parser--*identifier))))

(defun julia-snail-parser--*start-macro ()
  (-snoc
   (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "macro") :macro)
   (julia-snail-parser--*identifier)))

(defun julia-snail-parser--*start-type ()
  (-snoc
   (julia-snail-parser--parsec-query (parsec-or
                                      (julia-snail-parser--*keyword "abstract type")
                                      (julia-snail-parser--*keyword "primitive type"))
                                     :type)
   (julia-snail-parser--*identifier)))

(defun julia-snail-parser--*start-struct ()
  (-snoc
   (julia-snail-parser--parsec-query (parsec-or
                                      (julia-snail-parser--*keyword "struct")
                                      (julia-snail-parser--*keyword "mutable struct"))
                                     :struct)
   (julia-snail-parser--*identifier)))

(defun julia-snail-parser--*start-if ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "if") :if))

(defun julia-snail-parser--*start-while ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "while") :while))

(defun julia-snail-parser--*start-for ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "for") :for))

(defun julia-snail-parser--*start-begin ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "begin") :begin))

(defun julia-snail-parser--*start-quote ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "quote") :quote))

(defun julia-snail-parser--*start-try ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "try") :try))

(defun julia-snail-parser--*start-let ()
  (julia-snail-parser--parsec-query (julia-snail-parser--*keyword "let") :let))

(defun julia-snail-parser--*block ()
  (parsec-and
   (julia-snail-parser--*whitespace)
   (parsec-collect*
    (parsec-or (julia-snail-parser--*start-module)
               (julia-snail-parser--*start-function)
               (julia-snail-parser--*start-macro)
               (julia-snail-parser--*start-type)
               (julia-snail-parser--*start-struct)
               (julia-snail-parser--*start-if)
               (julia-snail-parser--*start-while)
               (julia-snail-parser--*start-for)
               (julia-snail-parser--*start-begin)
               (julia-snail-parser--*start-quote)
               (julia-snail-parser--*start-try)
               (julia-snail-parser--*start-let))
    (parsec-many-till
     (julia-snail-parser--*expression)
     (parsec-lookahead
      (parsec-or
       (parsec-eof)
       (parsec-try (julia-snail-parser--*end)))))
    (julia-snail-parser--*end))))

(defun julia-snail-parser--*file ()
  ;; XXX: This should be simply:
  ;; (parsec-many
  ;;  (julia-snail-parser--*expression))
  ;; but that causes infinte loops with stray "end"s at the end of the file. :(
  (parsec-many-till
   (julia-snail-parser--*expression)
   (parsec-lookahead
    (parsec-or
     (parsec-eof)
     (parsec-try (julia-snail-parser--*end))))))


;;; --- parse tree processing functions

(defun julia-snail-parser--parse (buf)
  (save-excursion
    (with-current-buffer buf
      (goto-char (point-min))
      (parsec-parse (julia-snail-parser--*file)))))

(defun julia-snail-parser--blocks (tree)
  (cond
   ((null tree)
    tree)
   ((atom tree)
    nil)
   ((and (listp tree)
         (listp (-first-item tree))
         (keywordp (-first-item (-first-item tree))))
    (let* ((block tree)
           (head (-first-item block))
           (body (-second-item block))
           (tail (-last-item block)))
      (-remove #'null (list (-first-item head)
                            (-second-item head)
                            (+ 3 (-second-item tail)) ; end location
                            (when (-third-item head) (substring-no-properties (-third-item head)))
                            (unless (equal body tail)
                              (-remove #'null (-map #'julia-snail-parser--blocks body)))))))
   (t ; list
    (-remove #'null (cons (julia-snail-parser--blocks (car tree))
                          (julia-snail-parser--blocks (cdr tree)))))))

(defun julia-snail-parser--block-path (blocks pt)
  (cl-labels ((helper (node)
                      (if (keywordp (-first-item node))
                          (when (and (>= pt (-second-item node))
                                     (<= pt (-third-item node)))
                            (list (-first-item node)
                                  (-second-item node)
                                  (-third-item node)
                                  (if (stringp (-fourth-item node))
                                      (-fourth-item node)
                                    :nil)
                                  (when (listp (-last-item node))
                                    (when-let (child-check (helper (-last-item node)))
                                      child-check))))
                        (-first-item (-remove #'null (-map #'helper node))))))
    (-partition
     4
     (-map (lambda (x) (if (eq :nil x) nil x))
           (-> (-remove #'null (-map #'helper blocks))
               -first-item
               -flatten)))))


;;; --- queries

(defun julia-snail-parser--query-module (block-path)
  ;; Remove everything from the list which is not a module, and return the
  ;; resulting module names. Fall back to Main if nothing comes back. Return
  ;; list of module names.
  (let ((module-blocks (-filter (lambda (block)
                                  (eq :module
                                      (-first-item block)))
                                block-path)))
    (if (null module-blocks)
        (list "Main") ; default
      (-map #'-fourth-item module-blocks))))

(defun julia-snail-parser--query-top-level-block (block-path)
  (cl-loop with current-top-block = nil
           for block in block-path
           if (eq :module (-first-item block))
           collect (-fourth-item block) into module
           and do (setq current-top-block nil)
           else do (when (null current-top-block) (setq current-top-block block))
           finally return
           (if (null current-top-block)
               (error "Unable to parse top-level block")
             (list :module (or module (list "Main"))
                   :block current-top-block))))


;;; --- entry point

(defun julia-snail-parser-query (buf pt query)
  (let ((tree (julia-snail-parser--parse buf)))
    (if (parsec-error-p tree)
        (error "Buffer does not parse; check Julia syntax")
      (let* ((blocks (julia-snail-parser--blocks tree))
             (block-path (julia-snail-parser--block-path blocks pt)))
        (cond ((eq :module query)
               (julia-snail-parser--query-module block-path))
              ((eq :top-level-block query)
               (julia-snail-parser--query-top-level-block block-path))
              (t (message (format "Unknown Snail parser query: %s" query))))))))


;;; --- done

(provide 'julia-snail-parser)
