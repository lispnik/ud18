(defpackage #:ud18
  ;; Uses #:ble, so the octet primitives, MAC conversion, AD-record parsing,
  ;; scanning and the whole ATT/GATT client come from the shared library
  ;; rather than being reimplemented here -- which is what they were until
  ;; this package stopped carrying its own copy of all of it.
  ;;
  ;; NOTE the inheritance hazard: a DEFUN in this package of a name #:ble
  ;; exports does not shadow it, it overwrites it. If you need a UD18-specific
  ;; variant of something generic, give it its own name.
  (:use #:common-lisp #:ble)
  (:documentation
   "Client library for the ATORCH UD18 USB/DC power meter over BLE.

The UD18 exposes a plain HM-10-style serial-over-GATT bridge: service
0xFFE0, characteristic 0xFFE1 (notify + write). Once you subscribe, it
pushes one 36-byte measurement frame per second, unsolicited and forever.
There is no request/response cycle to speak of for reading -- you connect,
subscribe, and listen.

The package is split across two ASDF systems along the platform seam:

  ud18/core -- src/protocol.lisp and src/commands.lisp: framing, checksum,
               measurement decoding, the command set. Portable; depends only
               on ble/core, which itself has no dependencies. Fully
               unit-tested, and the tests need no BLE stack.
  ud18/ble  -- src/device.lisp: connecting to a meter and streaming from it.
               Everything underneath -- HCI sockets, scanning, ATT/GATT -- is
               the shared `ble` system, not a copy of it living here.")
  (:export
   ;; --- framing (portable core) ---
   #:+frame-length+
   #:frame-checksum
   #:checksum-valid-p
   #:frame-magic-p
   #:frame-class
   #:frame-device-type
   #:encode-frame
   ;; --- decoded measurement ---
   #:reading
   #:reading-p
   #:decode-frame
   #:decode-frame-or-nil
   #:reading-raw
   #:reading-device-type
   #:reading-volts
   #:reading-amps
   #:reading-watts
   #:reading-capacity-mah
   #:reading-capacity-ah
   #:reading-energy-wh
   #:reading-d-minus-volts
   #:reading-d-plus-volts
   #:reading-temperature-c
   #:reading-run-hours
   #:reading-run-minutes
   #:reading-run-seconds
   #:reading-run-time-seconds
   #:reading-backlight-seconds
   #:backlight-description
   #:reading-undecoded
   #:reading-undecoded-offset
   #:+undecoded-start+
   #:format-run-time
   ;; --- commands (host -> meter) ---
   #:+commands+
   #:+command-frame-length+
   #:+reply-frame-length+
   #:+reply-statuses+
   #:command-info
   #:command-opcode
   #:command-supported-p
   #:encode-command
   #:reply
   #:reply-p
   #:reply-frame-p
   #:decode-reply
   #:reply-raw
   #:reply-status
   #:reply-status-code
   ;; --- conditions ---
   #:ud18-error
   #:frame-error
   #:frame-error-frame
   #:bad-magic
   #:bad-length
   #:bad-checksum
   #:bad-checksum-expected
   #:bad-checksum-actual
   #:characteristic-not-found
   #:characteristic-not-found-address
   #:characteristic-not-found-found
   #:unsupported-device-type
   #:unsupported-device-type-code
   ;; --- the device (src/device.lisp, system ud18/ble) ---
   #:+ud18-service-uuid+
   #:+ud18-char-uuid+
   #:ud18-like-p
   #:find-meters
   #:connection
   #:connection-p
   #:connect
   #:disconnect
   #:with-connection
   #:connection-chan
   #:connection-transport
   #:connection-mtu
   #:connection-address
   #:connection-addr-type
   #:connection-value-handle
   #:connection-cccd-handle
   #:connection-frames
   #:connection-bad-frames
   #:next-frame
   #:next-reading
   #:stream-readings
   #:send-command
   #:drain
   #:send-raw-command
   #:find-reply))
