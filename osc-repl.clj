(require 'clojure.main)

(clojure.main/repl
 :init #(apply require clojure.main/repl-requires)
 :read #(let [form (clojure.main/repl-read %1 %2)]
          (when-not (or (identical? form %1) (identical? form %2))
            (print "\u001b]133;C\u0007")
            (flush))
          form)
 :prompt #(do
            (print "\u001b]133;A\u0007")
            (printf "%s=> " (ns-name *ns*))
            (print "\u001b]133;B\u0007"))
 :print #(do
           (prn %)
           (print "\u001b]133;D;0\u0007")
           (flush))
 :caught #(do
            (clojure.main/repl-caught %)
            (print "\u001b]133;D;1\u0007")
            (flush)))
