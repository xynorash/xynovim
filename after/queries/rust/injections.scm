;; extends

; SQL inside sqlx: the macros (query!, query_as!, query_scalar!, query_unchecked!,
; ...) and the runtime functions (query, query_as, query_scalar, with or
; without a turbofish). Only string literals that start like a statement are
; injected, so bind arguments such as "alice" are left alone (the keyword must be
; a whole word, so "selection" is not SQL). The leading whitespace is
; [[:space:]]: \s does not match the newline of a multi-line string.

; sqlx::query!("...") / query_as!(Row, "...")
((macro_invocation
  macro: [
    (identifier) @_name
    (scoped_identifier
      name: (identifier) @_name)
  ]
  (token_tree
    [
      (string_literal
        (string_content) @injection.content)
      (raw_string_literal
        (string_content) @injection.content)
    ]))
  (#any-of? @_name "query" "query_as" "query_scalar" "query_unchecked" "query_as_unchecked" "query_scalar_unchecked")
  (#match? @injection.content "\\c^[[:space:]]*(select|insert|update|delete|with|create|alter|drop|replace|values|pragma|begin|commit|rollback|truncate|explain|vacuum|analyze|attach|detach|reindex|savepoint|release|set|show|grant|revoke|call|merge|lock)>")
  (#set! injection.language "sql"))

; sqlx::query("...") / query_as::<_, Row>("...")
((call_expression
  function: [
    (identifier) @_name
    (scoped_identifier
      name: (identifier) @_name)
    (generic_function
      function: [
        (identifier) @_name
        (scoped_identifier
          name: (identifier) @_name)
      ])
  ]
  arguments: (arguments
    [
      (string_literal
        (string_content) @injection.content)
      (raw_string_literal
        (string_content) @injection.content)
    ]))
  (#any-of? @_name "query" "query_as" "query_scalar")
  (#match? @injection.content "\\c^[[:space:]]*(select|insert|update|delete|with|create|alter|drop|replace|values|pragma|begin|commit|rollback|truncate|explain|vacuum|analyze|attach|detach|reindex|savepoint|release|set|show|grant|revoke|call|merge|lock)>")
  (#set! injection.language "sql"))
