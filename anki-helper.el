;;; anki-helper.el --- Manage your Anki cards in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Eli Qian

;; Author: Eli Qian <eli.q.qian@gmail.com>
;; URL: https://github.com/Elilif/emacs-anki-helper
;; Keywords: flashcards
;; Version: 1.0.0
;; Package-Requires: ((emacs "28.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Manage your Anki cards in Emacs
;; some functions and variables are stolen from
;; https://github.com/eyeinsky/org-anki

;;; Code:

(require 'cl-lib)
(require 'thunk)
(require 'org)
(require 'ox)
(require 'org-element)
(require 'org-macs)
(require 'json)

(defconst anki-helper-prop-note-id "ANKI_NOTE_ID"
  "Note ID used to identify an Anki note.")
(defconst anki-helper-prop-note-hash "ANKI_NOTE_HASH"
  "Used to determine whether the note has been modified.")
(defconst anki-helper-prop-deck "ANKI_DECK"
  "Specify Anki deck name.")
(defconst anki-helper-match "ANKI_MATCH"
  "A tags/property/todo match as it is used in the agenda tags view.
Only headlines that are matched by this query will be considered
during the iteration.

See Info node `(org) Matching tags and properties'.")
(defconst anki-helper-note-type "ANKI_NOTE_TYPE"
  "Specify the Anki note type.")
(defconst anki-helper-prop-global-tags "ANKI_TAGS"
  "Specify Anki note tags.")

(defgroup anki-helper nil
  "Customizations for anki-helper."
  :group 'applications)

(defcustom anki-helper-ankiconnnect-listen-address "http://127.0.0.1:8765"
  "The address of AnkiConnect"
  :type 'string
  :group 'anki-helper)

(defcustom anki-helper-default-note-type "Basic"
  "Default note type.

This variable will be used if none is set on the org item nor as
a global property."
  :type 'string
  :group 'anki-helper)

(defcustom anki-helper-default-tags nil
  "Default tags.

This variable will be used if none is set on the org item nor as
a global property."
  :type '(repeat string)
  :group 'anki-helper)

(defcustom anki-helper-allow-duplicates nil
  "When set to t, allow duplicate notes."
  :type '(choice (const :tag "Yes" t)
                 (const :tag "No" nil))
  :group 'anki-helper)

(defcustom anki-helper-default-match nil
  "A tags/property/todo match as it is used in the agenda tags view.
Only headlines that are matched by this query will be considered
during the iteration. See Info node `(org) Matching tags and
properties'.

This variable will be used if none is set on the org item nor as
global property."
  :type 'string
  :group 'anki-helper)

(defcustom anki-helper-default-deck "Default"
  "Default deck name.

This variable will be used if none is set on the org item nor as
a global property."
  :type 'string
  :group 'anki-helper)

(defcustom anki-helper-inherit-tags t
  "Inherit tags, set to nil to turn off."
  :type 'boolen
  :group 'anki-helper)

(defcustom anki-helper-note-types '(("Basic" "Front" "Back")
                                    ("Basic (and reversed card)" "Front" "Back")
                                    ("Basic (optional reversed card)" "Front" "Back")
                                    ("Cloze" "Text" "Back Extra"))
  "Default fields for note types."
  :group 'anki-helper
  :type '(repeat (list (repeat string))))

(defcustom anki-helper-media-directory "~/.local/share/Anki2/User 1/collection.media/"
  "Default Anki media directory."
  :type 'directory
  :group 'anki-helper)

;; see:
;; https://github.com/ankitects/anki/blob/main/qt/aqt/editor.py#L62
(defcustom anki-helper-audio-formats '("3gp" "aac" "avi" "flac" "flv" "m4a"
                                       "mkv" "mov" "mp3" "mp4" "mpeg" "mpg"
                                       "oga" "ogg" "ogv" "ogx" "opus" "spx"
                                       "swf" "wav" "webm")
  "audio formats supported by Anki."
  :type 'list
  :group 'anki-helper)

(defcustom anki-helper-callback-alist
  '((anki-helper-entry-delete . anki-helper-entry-delete-callback)
    (anki-helper-entry-delete-all . anki-helper-entry-delete-callback)
    (anki-helper-entry-sync-all . anki-helper-entry-sync-callback)
    (anki-helper-entry-update-all . anki-helper-entry-update-callback)
    (anki-helper-find-notes . anki-helper-find-notes-callback))
  "Alist of (FUNCTION . CALLBACK) pairs.

Used by `anki-helper--curl-sentinel'.

FUNCTION is the function that calls `anki-helper-request'.

CALLBACK is the callback function for FUNCTION."
  :type 'alist
  :group 'anki-helper)

(defcustom anki-helper-fields-get-alist
  '(("Basic" . anki-helper-fields-get-default)
    ("Cloze" . anki-helper-fields-get-cloze))
  "Alist of (NOTE-TYPE . FUNCTION) pairs.

Used by `anki-helper--entry-get-fields'.

FUNCTION should return a list of string, where each string
corresponds to a field in NOTE-TYPE."
  :type 'alist
  :group 'anki-helper)

(defcustom anki-helper-skip-function nil
  "Function used to skip entries.

Given as the SKIP argument to org-map-entries, see its help for
how to use it to include or skip an entry from being synced."
  :type 'function
  :group 'anki-helper)

(defcustom anki-helper-default-callback #'anki-helper--default-callback
  "Function used to deal with the info returned by AnkiConnect.

Accept two arguments: INFO and RESULT."
  :type 'function
  :group 'anki-helper)

(defcustom anki-helper-cloze-use-emphasis nil
  "Non-nil means emphasized text will be treated as cloze deletions.

The available options are:
- nil
- bold
- italic
- underline
- verbatim
- code
- strike-through

For instance:

\"Man landed on the moon in =1969=\" will be converted into \"Man
landed on the moon in {{c1:1969}}\"."
  :type '(choice
          (const :tag "None" nil)
          (const :tag "Bold" bold)
          (const :tag "Italic" italic)
          (const :tag "Underline" underline)
          (const :tag "Verbatim" verbatim)
          (const :tag "Code" code)
          (const :tag "Strike-through" strike-through))
  :group 'anki-helper)

(defcustom anki-helper-ox-filter-latex-env-functions '(anki-helper--ox-html-latex-env)
  "List of functions applied to a transcoded latex-environment.

See `org-export-filter-latex-environment-functions' for details."
  :type 'list
  :group 'anki-helper)

(defcustom anki-helper-ox-filter-latex-frag-functions '(anki-helper--ox-html-latex-frag)
  "List of functions applied to a transcoded latex-fragment.

See `org-export-filter-latex-fragment-functions' for details."
  :type 'list
  :group 'anki-helper)

(cl-defstruct anki-helper--note maybe-id fields tags deck model orig-pos hash)

(defvar anki-helper--org2html-image-counter 0)
(defvar anki-helper--process-alist nil)

(defvar anki-helper-action-alist
  '((addNote . anki-helper--action-addnote)
    (addNotes . anki-helper--action-addnotes)
    (deleteNotes . anki-helper--action-deletenotes)
    (updateNote . anki-helper--action-updatenote)
    (multi . anki-helper--action-multi)
    (guiBrowse . anki-helper--action-guibrowse)
    (findNotes . anki-helper--action-findNotes)
    (sync . anki-helper--action-sync)))

(defun anki-helper--get-note-fields (note)
  "Get note fields for NOTE."
  (cdr (assoc note anki-helper-note-types)))

(defun anki-helper--body (action &optional params)
  "Wrap ACTION and PARAMS to a json payload AnkiConnect expects."
  (if params
      `(("action" . ,action)
        ("version" . 6)
        ("params" . ,params))
    `(("action" . ,action)
      ("version" . 6))))

(defun anki-helper--note-to-json (note)
  "Create a NOTE json structure."
  `(("deckName" . ,(anki-helper--note-deck note))
    ("modelName" . ,(anki-helper--note-model note))
    ("fields"    . ,(anki-helper--note-fields note))
    ("tags" . ,(or (anki-helper--note-tags note) ""))
    ("options" .
     (("allowDuplicate" . ,(or anki-helper-allow-duplicates :json-false))
      ("duplicateScope" . "deck")))))

(defun anki-helper--action-addnote (note)
  "Create an `addNote' json structure for NOTE."
  (anki-helper--body
   "addNote"
   `(("note" .
      ,(anki-helper--note-to-json note)))))

(defun anki-helper--action-addnotes (notes)
  "Create an `addNotes' json structure for NOTES."
  (anki-helper--body
   "addNotes"
   `(("notes" .
      (,@(mapcar #'anki-helper--note-to-json notes))))))

(defun anki-helper--action-updatenote (note)
  "Create an `updateNote' json structure for NOTES."
  (anki-helper--body
   "updateNote"
   `(("note" .
      (("id" . ,(anki-helper--note-maybe-id note))
       ("fields" . ,(anki-helper--note-fields note))
       ("tags" . ,(or (anki-helper--note-tags note) "")))))))

(defun anki-helper--action-multi (actions)
  "Create a `multi' json structure for ACTIONS."
  (anki-helper--body
   "multi"
   `(("actions" .
      (,@actions)))))

(defun anki-helper--action-deletenotes (ids)
  "Create a `deleteNotes' json structure for IDS."
  (anki-helper--body
   "deleteNotes"
   `(("notes" .
      (,@ids)))))

(defun anki-helper--action-guibrowse (query)
  "Create a `guiBrowse' json structure for QUERY."
  (anki-helper--body
   "guiBrowse"
   `(("query" . ,query))))

(defun anki-helper--action-findNotes (query)
  "Create a `findNotes' json structure for QUERY."
  (anki-helper--body
   "findNotes"
   `(("query" . ,query))))

(defun anki-helper--action-sync (&rest _args)
  "Synchronizes the local Anki collections with AnkiWeb."
  (anki-helper--body "sync"))

(defun anki-helper--get-global-keyword (keyword)
  "Get global property by KEYWORD."
  (cadar (org-collect-keywords (list keyword))))

(defun anki-helper--find-prop (name default)
  "Find property with NAME from
1. item,
2. inherited from parents
3. in-buffer setting
4. otherwise use DEFAULT"
  (thunk-let
      ((prop-item (org-entry-get nil name t))
       (keyword-global (anki-helper--get-global-keyword name)))
    (cond
     ((stringp prop-item) prop-item)
     ((stringp keyword-global) keyword-global)
     ((stringp default) default)
     (t (error "No property '%s' in item nor file nor set as default!"
               name)))))

(defun anki-helper--get-tags ()
  "Get all tags for the current note."
  (append
   (delete-dups
    (split-string
     (let ((global-tags (anki-helper--get-global-keyword anki-helper-prop-global-tags)))
       (concat
        (if anki-helper-inherit-tags
            (substring-no-properties (or (org-entry-get nil "ALLTAGS") ""))
          (org-entry-get nil "TAGS"))
        global-tags))
     ":" t))
   anki-helper-default-tags))

(defun anki-helper--get-match ()
  "Compute the match argument of `org-map-entries'.

See `anki-helper-match' and `anki-helper-default-match'."
  (let ((file-global (anki-helper--get-global-keyword anki-helper-match)))
    (if (stringp file-global)
        file-global
      anki-helper-default-match)))

(defun anki-helper--make-cloze (string)
  (let ((data (org-element-parse-secondary-string string `(,anki-helper-cloze-use-emphasis)))
        (anki-helper--cloze-counter 0))
    (mapconcat (lambda (elt)
                 (if (stringp elt)
                     elt
                   (concat (format "{{c%d::%s}}"
                                   (cl-incf anki-helper--cloze-counter)
                                   (if (eq anki-helper-cloze-use-emphasis 'verbatim)
                                       (org-element-property :value elt)
                                     (if-let* ((content (car (org-element-contents elt)))
                                               ((stringp content)))
                                         content
                                       (org-element-property :value content))))
                           (make-string (org-element-property :post-blank elt)
                                        32))))
               data "")))

(defun anki-helper--copy-ltximg (latex)
  "Copy the preview image of LATEX to the Anki media directory."
  (when (string-match-p " $\\|\n\n$" (substring latex -2))
    (setq latex (substring latex 0 -1)))
  (let* ((face (face-at-point))
         (fg (let ((color (plist-get org-format-latex-options
                                     :foreground)))
               (cond
                ((eq color 'auto)
                 (face-attribute face :foreground nil 'default))
                ((eq color 'default)
                 (face-attribute 'default :foreground nil))
                (t color))))
         (bg (let ((color (plist-get org-format-latex-options
                                     :background)))
               (cond
                ((eq color 'auto)
                 (face-attribute face :background nil 'default))
                ((eq color 'default)
                 (face-attribute 'default :background nil))
                (t color))))
         (hash (sha1 (prin1-to-string
                      (list org-format-latex-header
                            org-latex-default-packages-alist
                            org-latex-packages-alist
                            org-format-latex-options
                            'forbuffer latex fg bg))))
         (processing-info
          (cdr (assq org-preview-latex-default-process
                     org-preview-latex-process-alist)))
         (imagetype (or (plist-get processing-info :image-output-type) "png"))
         (prefix (concat org-preview-latex-image-directory
                         "org-ltximg"))
         (dir default-directory)
         (absprefix (expand-file-name prefix dir))
         (todir (file-name-directory absprefix))
         (origin-file (format "%s_%s.%s" absprefix hash imagetype))
         (base-name (file-name-nondirectory origin-file))
         (target-file (file-name-concat
                       anki-helper-media-directory
                       base-name))
         (options
          (org-combine-plists
           org-format-latex-options
           `(:foreground ,fg :background ,bg))))
    (unless (file-directory-p todir)
      (make-directory todir t))
    (unless (file-exists-p origin-file)
      (org-create-formula-image
       latex origin-file options 'forbuffer org-preview-latex-default-process))
    (copy-file origin-file target-file t)
    base-name))

(defun anki-helper--ox-html-latex-frag (text backend _info)
  "Translate TEXT fragment to html."
  (when (eq backend 'html)
    (let* ((base-name (anki-helper--copy-ltximg text))
           (img (format " <img class=\"latex\" src=\"%s\"> " base-name)))
      (if (or (string-match-p (cadr (assoc "\\[" org-latex-regexps)) text)
              (string-match-p (cadr (assoc "$$" org-latex-regexps)) text))
          (format "<br>%s<br>" img)
        img))))

(defun anki-helper--ox-html-latex-env (text backend _info)
  "Translate TEXT enironment to html."
  (when (eq backend 'html)
    (let ((base-name (anki-helper--copy-ltximg text)))
      (format " <img class=\"latex\" src=\"%s\"> " base-name))))

(defun anki-helper--ox-html-link (text backend info)
  (when (eq backend 'html)
    (when-let*
        ((link (nth anki-helper--org2html-image-counter
                    (org-element-map (plist-get info :parse-tree) 'link 'identity)))
         (link-path (org-element-property :path link))
         (file-exists-p (file-exists-p link-path))
         (file-extension (file-name-extension link-path))
         (link-type (org-element-property :type link))
         (hash (md5 (format "%s%s%s" (random) text (recent-keys))))
         (new-name (file-name-with-extension hash file-extension))
         (full-path (file-name-concat
                     anki-helper-media-directory
                     new-name)))
      (cond
       ((and (plist-get info :html-inline-images)
             (org-export-inline-image-p link
                                        (plist-get info :html-inline-image-rules)))
        (copy-file link-path full-path)
        (setq text (replace-regexp-in-string "img src=\"\\(.*?\\)\"" new-name text
                                             nil nil 1)))
       ((member file-extension anki-helper-audio-formats)
        (copy-file link-path full-path)
        (setq text (format "<br>[sound:%s]" new-name))))))
  (cl-incf anki-helper--org2html-image-counter)
  text)

(defun anki-helper--org2html (string)
  (let ((org-export-filter-link-functions '(anki-helper--ox-html-link))
        (org-export-filter-latex-environment-functions anki-helper-ox-filter-latex-env-functions)
        (org-export-filter-latex-fragment-functions anki-helper-ox-filter-latex-frag-functions)
        (anki-helper--org2html-image-counter 0))
    (org-export-string-as string 'html t '(:with-toc nil))))

(defun anki-helper--default-callback (_info _result)
  (message "Synchronizing...done"))

(defun anki-helper--get-note-hash ()
  (let* ((note-type (anki-helper--find-prop
                     anki-helper-note-type
                     anki-helper-default-note-type))
         (fields (anki-helper--entry-get-fields note-type))
         (fields-string (anki-helper--filelds2string fields ""))
         (tags (anki-helper--get-tags)))
    (md5 (mapconcat #'identity (push fields-string tags) ""))))

(defun anki-helper-entry-set-hash ()
  (org-set-property anki-helper-prop-note-hash
                    (anki-helper--get-note-hash)))

(defun anki-helper--entry-update-callback (info _result)
  (dolist (marker info)
    (save-excursion
      (with-current-buffer (marker-buffer marker)
        (goto-char marker)
        (anki-helper-entry-set-hash))))
  (message "Updating cards...done"))

(defun anki-helper-entry-update-callback (info result)
  (run-with-idle-timer 1 nil #'anki-helper--entry-update-callback info result))

(defun anki-helper--entry-sync-callback (info result)
  (dolist (pair (seq-mapn #'cons info result))
    (if-let ((marker (car pair))
             (id (cdr pair)))
        (save-excursion
          (with-current-buffer (marker-buffer marker)
            (goto-char marker)
            (anki-helper-entry-set-hash)
            (org-set-property anki-helper-prop-note-id
                              (number-to-string id))))
      (message "Couldn't add note.")))
  (message "Synchronizing cards...done."))

(defun anki-helper-entry-sync-callback (info result)
  (run-with-idle-timer 1 nil #'anki-helper--entry-sync-callback info result))

(defun anki-helper--entry-delete-callback (info _result)
  (dolist (marker info)
    (save-excursion
      (with-current-buffer (marker-buffer marker)
        (goto-char marker)
        (org-entry-delete nil anki-helper-prop-note-hash)
        (org-entry-delete nil anki-helper-prop-note-id))))
  (message "Deleting cards...done."))

(defun anki-helper-entry-delete-callback (info result)
  (run-with-idle-timer 1 nil #'anki-helper--entry-delete-callback info result))

(defun anki-helper-find-notes-callback (info result)
  (if result
      (let ((query info))
        (anki-helper-request 'guiBrowse query))
    (message "anki-helper: Query failed!")))

(defun anki-helper--curl-sentinel (process _status)
  "Process sentinel for AnkiConnect curl requests.

PROCESS and _STATUS are process parameters."
  (let ((proc-buf (process-buffer process)))
    (when (eq (process-status process) 'exit)
      (with-current-buffer proc-buf
        (goto-char (point-min))
        (let* ((json-object-type 'plist)
               (json-array-type 'list)
               result)
          (setq result (json-read))
          (if-let ((err (plist-get result :error)))
              (message (format "Error: %s" err))
            (let* ((result (plist-get result :result))
                   (info (alist-get process anki-helper--process-alist))
                   (command (plist-get info :command))
                   (orig-info (plist-get info :orig-info)))
              (funcall (alist-get command anki-helper-callback-alist anki-helper-default-callback)
                       orig-info result))))))
    (setf (alist-get process anki-helper--process-alist nil 'remove) nil)
    (kill-buffer proc-buf)))

(defun anki-helper--request-args (action body)
  "Produce list of arguments for calling Curl.

See `anki-helper-request' for details of ACTION and BODY."
  (let* ((func (alist-get action anki-helper-action-alist))
         (file-name (make-temp-file "anki-helper")))
    (with-temp-file file-name
      (setq buffer-file-coding-system 'utf-8)
      (set-buffer-multibyte t)
      (insert (json-encode (funcall func body))))
    (list
     anki-helper-ankiconnnect-listen-address
     "--silent"
     (format "-X%s" "POST")
     (format "-d@%s" file-name))))

(defun anki-helper-request (action body &optional info)
  "Perform HTTP POST request to AnkiConnect.

ACTION should be a symbol supported by AnkiConnect.

BODY is the data used by functions in `anki-helper-action-alist'.

INFO should be a plist in the following format:
(:command FUNCTION :orig-info ORIG-INFO).

FUNCTION is the function that calls `anki-helper-request'.

ORIG-INFO is a list of makers which records the position of each
entry."
  (let* ((args (anki-helper--request-args action body))
         (process (apply #'start-process
                         "anki-helper"
                         (generate-new-buffer "*anki-helper*")
                         "curl"
                         args)))
    (with-current-buffer (process-buffer process)
      (set-process-query-on-exit-flag process nil)
      (setf (alist-get process anki-helper--process-alist)
            info)
      (set-process-sentinel process #'anki-helper--curl-sentinel))))


;;;; fields

(defun anki-helper-fields-get-default ()
  "Default function for getting filed info of the current entry."
  (let* ((elt (org-element-at-point))
         (front (org-element-property :raw-value elt))
         (contents-begin (org-element-property :contents-begin elt))
         (robust-begin (or (org-element-property :robust-begin elt)
                           contents-begin))
         (beg (if (or (= contents-begin robust-begin)
                      (= (+ 2 contents-begin) robust-begin))
                  contents-begin
                (1+ robust-begin)))
         (contents-end (org-element-property :contents-end elt))
         ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
         ;; CL comment out
         ; (back (buffer-substring-no-properties
         ;        beg (1- contents-end)))
         (back (my/org-get-subheadings))
         )
         ;; (message "original back is : %s" (type-of back))
         ; (pp back)
         ; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
         ; (message "my back is : %s" (type-of myback))
         ; (pp myback)
         ; (setq back (replace-regexp-in-string "^\\([[:alnum:]]+\\)" "\\1" back))
         (setq back (replace-regexp-in-string "\(" "\n" back))  ; 去掉左括号
         (setq back (replace-regexp-in-string "\)" "\n" back))  ; 将右括号替换为 \n
         (setq back (replace-regexp-in-string "-" "\n\n-" back))  ; bullet
    (list front back))
  )

(defun anki-helper-fields-get-cloze ()
  "Default function for getting filed info of the current entry for
\"Cloze\" note-type."
  (let* ((pair (anki-helper-fields-get-default))
         (back (cadr pair)))
    (list (if anki-helper-cloze-use-emphasis
              (anki-helper--make-cloze back)
            back)
          (car pair))))

(defun anki-helper--entry-get-fields (note-type)
  "Get the fileds info of the current entry for NOTE-TYPE."
  (let ((fields (anki-helper--get-note-fields note-type))
        (field-contents (funcall (alist-get
                                  note-type
                                  anki-helper-fields-get-alist
                                  #'anki-helper-fields-get-default
                                  nil #'string=))))
    (seq-mapn #'cons fields field-contents)))

(defun anki-helper--filelds2string (fields seprator)
  "Convert the contents in fields into a single string."
  (mapconcat #'cdr fields seprator))

(defun anki-helper--entry-get-content ()
  "Create an `anki-helper--note' struct for current Anki entry."
  (let* ((note-type (anki-helper--find-prop
                     anki-helper-note-type
                     anki-helper-default-note-type))
         (fields (anki-helper--entry-get-fields note-type))
         (maybe-id (org-entry-get nil anki-helper-prop-note-id))
         (deck (anki-helper--find-prop
                anki-helper-prop-deck
                anki-helper-default-deck))
         (tags (anki-helper--get-tags))
         (hash (md5 (format "%s%s"
                            (random)
                            (anki-helper--filelds2string fields "")))))
    (make-anki-helper--note
     :maybe-id (if (stringp maybe-id) (string-to-number maybe-id))
     :deck deck
     :fields fields
     :tags tags
     :model note-type
     :orig-pos (point-marker)
     :hash hash)))

(defun anki-helper--create-fields (note-type contents)
  "Create field pairs for NOTE-TYPE and CONTENTS.

NOTE-TYPE is a string, specifying the Anki note type. See
`anki-helper-note-types' for details.

CONTENTS is a list of string, where each string corresponds to a
field in NOTE-TYPE.

Example:

(anki-helper--create-fields \"Basic\" \\='(\"front side\" \"back
side\")) ==> ((\"Front\" . \"front side\") (\"Back\" . \"back
side\"))"
  (let* ((fields (anki-helper--get-note-fields note-type)))
    (seq-mapn #'cons fields contents)))

(defun anki-helper--note-update-fields (note new-fields)
  "Replace slot `fields' of NOTE with NEW-FIELDS.

NOTE is an `anki-helper--note' struct.

NEW-FIELDS is a string."
  (setf (cl-struct-slot-value 'anki-helper--note 'fields note)
        (anki-helper--create-fields
         (anki-helper--note-model note)
         (split-string
          new-fields
          (format "<p>\n%s\n</p>" (anki-helper--note-hash note))
          nil
          "\n+")))
  note)

(defun anki-helper--transform-notes (notes)
  (let* ((hash (md5 (format "%s%s" (random) (recent-keys))))
         (html (anki-helper--org2html
                (mapconcat
                 (lambda (note)
                   (let ((fields (anki-helper--note-fields note))
                         (hash (anki-helper--note-hash note)))
                     (format "\n\n%s\n\n"
                             (anki-helper--filelds2string
                              fields
                              (format "\n\n%s\n\n" hash)))))
                 notes (format "\n\n%s\n\n" hash)))))
    (seq-mapn #'anki-helper--note-update-fields
              notes
              (split-string html
                            (format "<p>\n%s\n</p>" hash)
                            t "\n+"))))

(defun anki-helper--entry-get-all (match &optional skip)
  "Gel all Anki entries in the current buffer.

Return a cons of notes and positions.

See `org-map-entries' for details about MATCH and SKIP."
  (when-let* ((notes (org-map-entries
                      #'anki-helper--entry-get-content
                      match
                      nil
                      (or skip anki-helper-skip-function)))
              (new-notes (anki-helper--transform-notes notes))
              (positions (mapcar (lambda (note)
                                   (anki-helper--note-orig-pos note))
                                 notes)))
    (cons new-notes positions)))

(defun anki-helper-entry-modified-p ()
  "Return t if the entry is modified, else nil."
  (let ((orig-hash (org-entry-get nil anki-helper-prop-note-hash))
        (new-hash (anki-helper--get-note-hash)))
    (if (or (when anki-helper-skip-function
              (funcall anki-helper-skip-function))
            (string= orig-hash new-hash))
        (point))))

(cl-defun anki-helper-create-note (contents &key id
                                            (tags (anki-helper--get-tags))
                                            (deck (anki-helper--find-prop
                                                   anki-helper-prop-deck
                                                   anki-helper-default-deck))
                                            (model (anki-helper--find-prop
                                                    anki-helper-note-type
                                                    anki-helper-default-note-type)))
  "Construct an object of type `anki-helper--note'.

CONTENTS should be a list of string, where each string
corresponds to a field in MODEL.

ID is a number, corresponding to the note id.

TAGS is a list of string.

Deck is a string, specifying where the note will be stored. Use
`anki-helper-default-deck' by default.

MODEL is a string, specifying the note type. Use
`anki-helper-default-note-type' by default."
  (let* ((fields (anki-helper--create-fields model contents))
         (hash (md5 (format "%s%s"
                            (random)
                            (anki-helper--filelds2string fields "")))))
    (make-anki-helper--note
     :maybe-id id
     :fields fields
     :tags tags
     :deck deck
     :model model
     :hash hash)))

(defun anki-helper-create-notes (notes)
  (let* ((hash (md5 (format "%s%s" (random) (recent-keys))))
         (html (anki-helper--org2html
                (mapconcat
                 (lambda (note)
                   (let ((fields (anki-helper--note-fields note))
                         (hash (anki-helper--note-hash note)))
                     (format "\n\n%s\n\n"
                             (anki-helper--filelds2string
                              fields
                              (format "\n\n%s\n\n" hash)))))
                 notes (format "\n\n%s\n\n" hash)))))

    (seq-mapn #'anki-helper--note-update-fields
              notes
              (split-string html (format "<p>\n%s\n</p>" hash) t "\n+"))))

;;;###autoload
(defun anki-helper-entry-sync-all ()
  "Sync all matched Anki entries in the current buffer.

See `org-map-entries', `anki-helper-skip-function' and
`anki-helper--get-match' for details."
  (interactive)
  (when-let* ((result (anki-helper--entry-get-all
                       (concat (format "-%s={.+}" anki-helper-prop-note-id)
                               (anki-helper--get-match))))
              (body (car result)))
    (anki-helper-request 'addNotes
                         body
                         (list :command 'anki-helper-entry-sync-all
                               :orig-info (cdr result)))))

;;;###autoload
(defun anki-helper-entry-sync ()
  "Sync the Anki entry under the cursor.

See `anki-helper-entry-sync-all' for details."
  (interactive)
  (save-window-excursion
    (save-restriction
      (org-narrow-to-subtree)
      (anki-helper-entry-sync-all))))

;;;###autoload
(defun anki-helper-entry-update-all (&optional force)
  "Update all modified Anki entries in the current buffer.

With a prefix argument FORCE, update all notes no matter whether
there are any changes.

See `org-map-entries', `anki-helper-entry-modified-p' and
`anki-helper--get-match' for details."
  (interactive "P")
  (if-let* ((result (anki-helper--entry-get-all
                     (concat (format "%s={.+}" anki-helper-prop-note-id)
                             (anki-helper--get-match))
                     (unless force
                       #'anki-helper-entry-modified-p)))
            (body (mapcar #'anki-helper--action-updatenote (car result))))
      (anki-helper-request 'multi
                           body
                           (list :command 'anki-helper-entry-update-all
                                 :orig-info (cdr result)))
    (message "anki-helper: no update needed.")))

;;;###autoload
(defun anki-helper-entry-update (&optional force)
  "Update the Anki entry under the cursor.

With a prefix argument FORCE, update current note no matter whether
there are any changes.

See `anki-helper-entry-update-all' for details."
  (interactive "P")
  (save-window-excursion
    (save-restriction
      (org-narrow-to-subtree)
      (anki-helper-entry-update-all force))))

;;;###autoload
(defun anki-helper-entry-delete-all ()
  "Delete all matched Anki entries in the current buffer.

See `org-map-entries' and `anki-helper--get-match' for details."
  (interactive)
  (when-let ((pairs (org-map-entries
                     (lambda ()
                       (when-let ((id (org-entry-get nil anki-helper-prop-note-id))
                                  (marker (point-marker)))
                         (cons (string-to-number id) marker)))
                     (concat
                      (format "%s={.+}" anki-helper-prop-note-id)
                      (anki-helper--get-match)))))
    (anki-helper-request 'deleteNotes
                         (mapcar #'car pairs)
                         (list :command 'anki-helper-entry-delete-all
                               :orig-info (mapcar #'cdr pairs)))))

;;;###autoload
(defun anki-helper-entry-delete ()
  "Delete the Anki entry under the cursor.

See `anki-helper-entry-delete-all' for details."
  (interactive)
  (when-let ((id (string-to-number
                  (org-entry-get nil anki-helper-prop-note-id))))
    (anki-helper-request 'deleteNotes
                         (list id)
                         (list :command 'anki-helper-entry-delete
                               :orig-info (list (point-marker))))))

;;;###autoload
(defun anki-helper-entry-browse ()
  "Browse entry at point on Anki's browser dialog with searching nid."
  (interactive)
  (if-let ((maybe-id (org-entry-get nil anki-helper-prop-note-id)))
      (anki-helper-request 'guiBrowse (concat "nid:" maybe-id))
    (message "anki-helper: please select a note.")))

;;;###autoload
(defun anki-helper-find-notes (query)
  "Invokes the Card Browser dialog and searches for a given QUERY."
  (interactive "sQuery: ")
  (if (string-empty-p query)
      (message "anki-helper: empty query!")
    (anki-helper-request 'findNotes query (list :command 'anki-helper-find-notes
                                                :orig-info query))))

;;;###autoload
(defun anki-helper-sync ()
  "Synchronizes the local Anki collections with AnkiWeb."
  (interactive)
  (anki-helper-request 'sync nil))

;;;###autoload
(defun anki-helper-set-front-region ()
  "Mark a region.

Use the text in the region as the fornt of the card. Call
`anki-helper-make-two-sided-card' to specify the back of the card
and create a two-sided flashcard."
  (interactive)
  (letrec ((ah-delete-sec-region (lambda ()
                                   (delete-overlay mouse-secondary-overlay)
                                   (advice-remove 'keyboard-quit ah-delete-sec-region))))
    (if (not (region-active-p))
        (user-error "Please select a region!")
      (secondary-selection-from-region)
      (advice-add 'keyboard-quit :before ah-delete-sec-region)
      (deactivate-mark t))))

;;;###autoload
(cl-defun anki-helper-make-two-sided-card (beg end &optional
                                               (front-transformer #'identity)
                                               (back-transformer #'identity))
  "Create a two-sided flashcard.

Use the text between START and END as the back of the card. Call
`anki-helper-set-front-region' to specify the front of the card.

By default, the card's model will be
`anki-helper-default-note-type' and it will be stored in
`anki-helper-default-deck'. See `anki-helper-create-note' for
more informations."
  (interactive "r")
  (unless (region-active-p)
    (user-error "Please select a region!"))
  (unless (overlay-start mouse-secondary-overlay)
    (user-error "Please call `anki-helper-set-front-region' first!"))
  (let* ((front (funcall front-transformer
                         (buffer-substring-no-properties
                          (overlay-start mouse-secondary-overlay)
                          (overlay-end mouse-secondary-overlay))))
         (back (funcall back-transformer
                        (buffer-substring-no-properties beg end)))
         (contents (list front back)))
    (anki-helper-request 'addNote (anki-helper-create-note
                                   (if (derived-mode-p 'org-mode)
                                       (mapcar #'anki-helper--org2html
                                               contents)
                                     contents)))
    (delete-overlay mouse-secondary-overlay)
    (deactivate-mark)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CL try to build a simple and better formatted card's back

(defvar my/org-include-body-text t
  "Non-nil means include body text of the current heading before subheadings.
Set this to nil to exclude body text.")

(defun my/org-get-subheadings ()
  "Return a list of body text (if included) and subheadings under the current heading.
If a subheading contains a link, only the description of the link is kept.
If a subheading contains a date or time, it is removed.
If `my/org-include-body-text' is non-nil, include the body text of the current heading."
  ;; (interactive)
  (let (body-text subheadings result heading-pos)
    (save-excursion
      (org-back-to-heading t)  ; Ensure the cursor is at the start of the heading
      (setq heading-pos (point))  ; Remember the position of the current heading

      ;; Get body text if `my/org-include-body-text' is non-nil
      ;; (when my/org-include-body-text
        (let ((start (progn
                       (forward-line)  ; Move to the line after the heading
                       (point)))
              (end (save-excursion
                     (outline-next-heading)
                     (if (not (outline-end-p))
                         (point)  ; Move to the next heading
                       (point-max)))))  ; If no next heading, use point-max
          (goto-char start)
          ;; Collect body text until the next heading or end of buffer
          (setq body-text (buffer-substring-no-properties start end))
          (setq body-text (string-trim body-text))) ;; )

      ;; Return to the original heading position
      (goto-char heading-pos)

      ;; If no body text, set body-text to current heading
      (unless body-text
        (setq body-text (org-get-heading t t t t)))

      ;; Collect subheadings
      (let ((level (org-outline-level)))  ; Get the current heading's level
        (while (and (outline-next-heading)  ; Move to the next heading
                    (> (org-outline-level) level))  ; Ensure it's a subheading
          (when (= (org-outline-level) (1+ level))  ; Only get first-level subheadings
            (let ((heading (org-get-heading t t t t)))
              ;; Remove links and keep only the description
              (setq heading (replace-regexp-in-string org-link-bracket-re "\\2" heading))
              ;; Remove date or time information
              (setq heading (replace-regexp-in-string "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\(\\+0000\\)?" "" heading))
              (push (format "- %s" heading) subheadings))))))

    ;; Ensure the first subheading is not included if it follows immediately after the heading with no body text
    (if (and (not body-text) (car subheadings))
        (setq subheadings (cdr subheadings)))

    (setq subheadings (reverse subheadings))  ; Reverse the list to maintain document order

    ;; Create the result list with body text and subheadings
    (setq result (if body-text
                     (cons body-text subheadings)
                   subheadings))

    ;; Output the results to a temp buffer
    (with-output-to-temp-buffer "*Subheadings*"
      (dolist (item result)
        (princ (format "%s\n" item))))
    (setq result (princ (format "%s\n" result)))
    result))  ; Return the result list

(defun outline-end-p ()
  "Return t if the current position is at the end of the outline."
  (save-excursion
    (goto-char (point-max))
    (not (outline-back-to-heading t))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;###autoload
; (defun anki-helper--entry-filter ()
;   "过滤当前光标所在标题下的条目。"
;   (interactive)
;   (save-excursion
;     (org-back-to-heading)
;     (let* ((element (org-element-at-point))
;            (title (org-element-property :raw-value element))
;            (body (anki-helper--get-body-text element))
;            (subheadings (anki-helper--get-subheadings element)))
;       (anki-helper--process-entry title body subheadings))))

; (defun anki-helper--get-body-text (element)
;   "获取当前heading的body text，不包括subheadings和PROPERTIES。"
;   (let ((begin (org-element-property :contents-begin element))
;         (end (org-element-property :contents-end element)))
;     (when (and begin end)
;       (string-trim
;        (replace-regexp-in-string
;         "^\\(?:\\*+ .*\n\\|:PROPERTIES:\n\\(?:.*\n\\)*?:END:\n\\)" ""
;         (buffer-substring-no-properties begin end))))))

; (defun anki-helper--get-subheadings (element)
;   "获取当前heading下的第一级subheadings。"
;   (let ((level (1+ (org-element-property :level element)))
;         subheadings)
;     (org-element-map element 'headline
;       (lambda (headline)
;         (when (= (org-element-property :level headline) level)
;           (push (org-element-property :raw-value headline) subheadings))))
;     (nreverse subheadings)))

; (defun anki-helper--process-entry (title body subheadings)
;   "处理收集到的条目。"
;   (let* ((front title)
;          (back (concat (string-trim body)
;                        (when subheadings
;                          (concat "\n"
;                                  (mapconcat (lambda (sh) (concat "- " sh))
;                                             subheadings "\n")))))
;          (note-type anki-helper-default-note-type)
;          (fields (list (cons (car (anki-helper--get-note-fields note-type)) front)
;                        (cons (cadr (anki-helper--get-note-fields note-type)) back)))
;          (deck anki-helper-default-deck)
;          (orig-pos (point-marker)))
;     (anki-helper-request 'addNote
;                          (anki-helper--note-to-json
;                           (make-anki-helper--note
;                            :maybe-id nil
;                            :fields fields
;                            :tags nil
;                            :deck deck
;                            :model note-type
;                            :orig-pos orig-pos)))))

(provide 'anki-helper)
;;; anki-helper.el ends here
