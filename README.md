# org-markgraf

Render `markgraf` Org source blocks as interactive diagrams in HTML export.

```org
#+begin_src markgraf
seed 1
keyframe v1 {
  +node client "Client"
  +node api "API"
  +edge client api
  client -> api "GET /"
}
#+end_src
```

```elisp
(add-to-list 'load-path "/path/to/org-markgraf")
(require 'org-markgraf)
(org-markgraf-setup)
```

HTML export replaces `markgraf` source blocks with `<div data-markgraf ...>`
embeds and loads `@markgrafhq/markgraf-embed` from unpkg. Org Babel execution
also returns an HTML result block for the current diagram.
