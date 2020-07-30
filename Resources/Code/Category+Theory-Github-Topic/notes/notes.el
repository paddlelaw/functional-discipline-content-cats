(require 'htmlize)

(setq org-html-htmlize-output-type 'inline-css)

(setq org-html-validation-link nil)

(setq org-html-postamble-format
      '(("en" "<p>Generated by <span class=\"author\">%a</span> on <span class=\"date\">%T</span> using <span class=\"creator\">%c</span>.\n")))

(let ((project              "notes")
      (base-directory       "~/org/notes/")
      (publishing-directory "~/org/notes/docs/"))
  (add-to-list
   'org-publish-project-alist
   `(,project
     :author "Eric Bailey"
     :base-directory ,base-directory
     :base-extension "org"
     :publishing-directory ,publishing-directory
     :exclude "\\(notes\\|README\\).org"
     :recursive t
     :auto-sitemap t
     :sitemap-filename "sitemap.org"
     :sitemap-title ""
     :sitemap-sort-files anti-chronologically
     :export-creator-info nil
     :export-author-info nil
     :html-postamble t
     :table-of-contents t
     :section-numbers nil
     :auto-preamble t
     :style-include-default nil
     :publishing-function org-html-publish-to-html))
  (add-to-list
   'org-publish-project-alist
   `(,(concat project "-site")
     :base-directory ,base-directory
     :base-extension "css\\|js\\|png\\|jpg\\|gif\\|pdf"
     :publishing-directory ,publishing-directory
     :recursive t
     :publishing-function org-publish-attachment
     :components (,project))))

;;; Reset org-publish-project-alist
;; (setq org-publish-project-alist nil)
