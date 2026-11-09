;;; anvil-server-dispatch-guards-test.el --- ERT for dispatch guards -*- lexical-binding: t; -*-

;;; Commentary:

;; Two opt-in guards for `anvil-server-process-jsonrpc', both nil by
;; default (historical behaviour preserved):
;;
;; * `anvil-server-autostart-on-request' — restart a stopped server
;;   instead of signalling.  For stdio transports the signalled error
;;   surfaces as empty emacsclient output, which the client cannot
;;   match to its request: an effective hang.
;;
;; * `anvil-server-dispatch-timeout' — answer an over-long request
;;   with a JSON-RPC internal error carrying the request id instead
;;   of blocking the transport indefinitely.

;;; Code:

(require 'ert)
(require 'json)
(require 'anvil)
(require 'anvil-server)

(ert-deftest anvil-server-dispatch-guards-test-stopped-server-errors ()
  "Default: a stopped server still signals."
  (let ((anvil-server--running nil)
        (anvil-server-autostart-on-request nil))
    (should-error
     (anvil-server-process-jsonrpc
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
      "guards-test"))))

(ert-deftest anvil-server-dispatch-guards-test-autostart ()
  "With autostart enabled, a stopped server is started transparently."
  (let ((anvil-server--running nil)
        (anvil-server-autostart-on-request t)
        (started nil))
    (cl-letf (((symbol-function 'anvil-server-start)
               (lambda (&rest _) (setq started t anvil-server--running t)))
              ((symbol-function 'anvil-server--validate-and-dispatch-request)
               (lambda (&rest _) "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")))
      (anvil-server-process-jsonrpc
       "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
       "guards-test")
      (should started))))

(ert-deftest anvil-server-dispatch-guards-test-timeout-carries-id ()
  "An over-long dispatch yields a timeout error with the request id."
  (let ((anvil-server--running t)
        (anvil-server-dispatch-timeout 0.05))
    (cl-letf (((symbol-function 'anvil-server--validate-and-dispatch-request)
               (lambda (&rest _)
                 ;; sit-for yields to the event loop so with-timeout fires.
                 (sit-for 1)
                 "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}")))
      (let ((resp (json-read-from-string
                   (anvil-server-process-jsonrpc
                    "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}"
                    "guards-test"))))
        (should (equal (alist-get 'id resp) 7))
        (should (string-match-p "timed out"
                                (alist-get 'message
                                           (alist-get 'error resp))))))))

(ert-deftest anvil-server-dispatch-guards-test-no-timeout-by-default ()
  "With the default nil timeout, dispatch is not wrapped."
  (let ((anvil-server--running t)
        (anvil-server-dispatch-timeout nil))
    (cl-letf (((symbol-function 'anvil-server--validate-and-dispatch-request)
               (lambda (&rest _)
                 "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}")))
      (let ((resp (json-read-from-string
                   (anvil-server-process-jsonrpc
                    "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"
                    "guards-test"))))
        (should (equal (alist-get 'id resp) 3))
        ;; json-read maps the empty result object to nil; presence of
        ;; the key (and absence of error) is what matters.
        (should (assq 'result resp))
        (should-not (assq 'error resp))))))

;;;; Notifications

(ert-deftest anvil-server-dispatch-guards-test-notifications-unanswered ()
  "A message without an id gets no answer, whatever its method.
JSON-RPC forbids answering a notification, and Claude Code drops a
connection that sends a message with a null id: it sends
notifications/roots/list_changed once a session gains a directory."
  (let ((anvil-server--running t))
    (dolist (method '("notifications/roots/list_changed" "notifications/initialized"
                      "notifications/cancelled" "notifications/unknown" "unknown/method"))
      (should-not (anvil-server-process-jsonrpc
                   (json-encode `((jsonrpc . "2.0") (method . ,method)))
                   "guards-test")))))

(ert-deftest anvil-server-dispatch-guards-test-unknown-method-answered ()
  "A request for an unknown method still gets method-not-found, with its id."
  (let* ((anvil-server--running t)
         (response (json-read-from-string
                    (anvil-server-process-jsonrpc
                     "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"unknown/method\"}"
                     "guards-test"))))
    (should (equal (alist-get 'id response) 9))
    (should (equal (alist-get 'code (alist-get 'error response))
                   anvil-server-jsonrpc-error-method-not-found))))

;;;; The listChanged capability

(defun anvil-server-dispatch-guards-test--sentinel ()
  "Return ok."
  "ok")

(defun anvil-server-dispatch-guards-test--capabilities (method relists)
  "Return the capabilities METHOD reports, as parsed.
METHOD is initialize or server/discover; RELISTS binds
`anvil-server-transport-relists'."
  (let ((anvil-server--running t)
        (anvil-server-transport-relists relists))
    (alist-get 'capabilities
               (alist-get 'result
                          (json-read-from-string
                           (anvil-server-process-jsonrpc
                            (format "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":%S%s}"
                                    method
                                    (if (equal method "server/discover")
                                        ",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}"
                                      ""))
                            "guards-caps-test"))))))

(ert-deftest anvil-server-dispatch-guards-test-list-changed-capability ()
  "Over a transport that relists, initialize declares listChanged for the lists the server has.
The stdio bridge announces a list changed when it drops an answer to
tools/list or resources/list the client gave up on, and a client acts
on that only when the server declared the capability.  server/discover
never declares it: a 2026-07-28 client would open a
subscriptions/listen stream, which the server does not serve."
  (anvil-server-register-tool #'anvil-server-dispatch-guards-test--sentinel
                              :id "guards-sentinel" :description "Sentinel"
                              :server-id "guards-caps-test")
  (anvil-server-register-resource "guards://resource" (lambda () "text")
                                  :name "Guards resource" :server-id "guards-caps-test")
  (unwind-protect
      (dolist (method '("initialize" "server/discover"))
        (dolist (relists '(t nil))
          (let ((capabilities (anvil-server-dispatch-guards-test--capabilities method relists))
                (declared (and relists (equal method "initialize") t)))
            (should (assq 'tools capabilities))
            (should (assq 'resources capabilities))
            (should (eq (alist-get 'listChanged (alist-get 'tools capabilities)) declared))
            (should (eq (alist-get 'listChanged (alist-get 'resources capabilities)) declared)))))
    (anvil-server-unregister-tool "guards-sentinel" "guards-caps-test")
    (anvil-server-unregister-resource "guards://resource" "guards-caps-test")))

(provide 'anvil-server-dispatch-guards-test)
;;; anvil-server-dispatch-guards-test.el ends here
