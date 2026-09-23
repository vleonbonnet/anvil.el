;;; anvil-server-modern-era-test.el --- ERT for dual-era MCP serving -*- lexical-binding: t; -*-
;;; Commentary:
;; MCP 2026-07-28 requests carry their version in params._meta and get
;; stateless results with resultType; initialize-era requests keep the
;; legacy shape.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'anvil)
(require 'anvil-server)
(require 'anvil-server-commands)
(require 'anvil-server-ert)

(defun anvil-server-modern-era-test-sentinel ()
  "Return a successful sentinel result."
  "ok")

(defmacro anvil-server-modern-era-test--with-server (&rest body)
  "Run BODY with the ERT server and modern-era test sentinel active."
  `(unwind-protect
       (progn
         (anvil-server-register-tool
          #'anvil-server-modern-era-test-sentinel
          :id "modern-era-test-sentinel"
          :description "Sentinel"
          :server-id anvil-server-ert-server-id)
         (when (anvil-server-running-p)
           (anvil-server-stop))
         (anvil-server-start)
         ,@body)
     (when (anvil-server-running-p)
       (anvil-server-stop))))

(defun anvil-server-modern-era-test--call (method &optional params-json)
  "Call METHOD with optional PARAMS-JSON and return its parsed response."
  (let* ((request (format "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":%S%s}"
                          method
                          (if params-json
                              (concat ",\"params\":" params-json)
                            "")))
         (response (anvil-server-process-jsonrpc
                    request anvil-server-ert-server-id)))
    (json-read-from-string response)))

(defconst anvil-server-modern-era-test--meta
  "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}")

(ert-deftest anvil-server-modern-era-test-discover ()
  "Discover reports complete modern-era metadata."
  (anvil-server-modern-era-test--with-server
   (let* ((response (anvil-server-modern-era-test--call
                     "server/discover" anvil-server-modern-era-test--meta))
          (result (alist-get 'result response))
          (capabilities (alist-get 'capabilities result))
          (supported-versions (alist-get 'supportedVersions result))
          (server-info
           (alist-get 'io.modelcontextprotocol/serverInfo
                      (alist-get '_meta result))))
     (should (equal "complete" (alist-get 'resultType result)))
     (should (vectorp supported-versions))
     (should (cl-find "2026-07-28" supported-versions :test #'equal))
     (should (cl-find "2025-03-26" supported-versions :test #'equal))
     (should (assq 'tools capabilities))
     (should (equal "anvil"
                    (alist-get 'name server-info))))))

(ert-deftest anvil-server-modern-era-test-modern-tools-list ()
  "Modern tools/list returns stateless cache metadata."
  (anvil-server-modern-era-test--with-server
   (let* ((response (anvil-server-modern-era-test--call
                     "tools/list" anvil-server-modern-era-test--meta))
          (result (alist-get 'result response)))
     (should (equal "complete" (alist-get 'resultType result)))
     (should (numberp (alist-get 'ttlMs result)))
     (should (equal "private" (alist-get 'cacheScope result)))
     (should (vectorp (alist-get 'tools result))))))

(ert-deftest anvil-server-modern-era-test-modern-tools-call ()
  "Modern tools/call returns a stateless result."
  (anvil-server-modern-era-test--with-server
   (let* ((params "{\"name\":\"modern-era-test-sentinel\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}")
          (response (anvil-server-modern-era-test--call
                     "tools/call" params))
          (result (alist-get 'result response)))
     (should (equal "complete" (alist-get 'resultType result))))))

(ert-deftest anvil-server-modern-era-test-unsupported-version ()
  "An unsupported protocol version returns structured error data."
  (anvil-server-modern-era-test--with-server
   (let* ((params "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1900-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}")
          (response (anvil-server-modern-era-test--call
                     "server/discover" params))
          (error (alist-get 'error response))
          (data (alist-get 'data error))
          (supported (alist-get 'supported data)))
     (should (equal -32022 (alist-get 'code error)))
     (should (equal "1900-01-01" (alist-get 'requested data)))
     (should (vectorp supported))
     (should (cl-find "2026-07-28" supported :test #'equal)))))

(ert-deftest anvil-server-modern-era-test-legacy-shape ()
  "Initialize-era requests retain legacy response shapes."
  (anvil-server-modern-era-test--with-server
   (let* ((initialize-params "{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{}}")
          (initialize-response
           (anvil-server-modern-era-test--call
            "initialize" initialize-params))
          (initialize-result (alist-get 'result initialize-response))
          (legacy-tools-response
           (anvil-server-modern-era-test--call "tools/list")))
     (should (equal "2025-03-26"
                    (alist-get 'protocolVersion initialize-result)))
     (should (null (assq 'resultType initialize-result)))
     (should (null (assq 'resultType
                         (alist-get 'result legacy-tools-response)))))))

(ert-deftest anvil-server-modern-era-test-server-discover-unavailable ()
  "The legacy server/discover method is unavailable."
  (anvil-server-modern-era-test--with-server
   (let* ((response (anvil-server-modern-era-test--call "server/discover"))
          (error (alist-get 'error response)))
     (should (equal -32601 (alist-get 'code error))))))

(provide 'anvil-server-modern-era-test)
;;; anvil-server-modern-era-test.el ends here
